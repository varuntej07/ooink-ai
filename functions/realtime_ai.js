const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');
const {initializeApp} = require('firebase-admin/app');
const {timingSafeEqual} = require('crypto');

// Shared secret the LiveKit agent sends in the x-ooink-embed-key header
// (backend/agent/rag_pipeline.py). Without it the public URL could be used to
// run up Vertex AI spend. Set with: firebase functions:secrets:set EMBED_SHARED_SECRET
const EMBED_SHARED_SECRET = defineSecret('EMBED_SHARED_SECRET');

function isAuthorizedCaller(request) {
  const expected = EMBED_SHARED_SECRET.value();
  const header = request.rawRequest?.headers?.['x-ooink-embed-key'];
  const given = Array.isArray(header) ? header[0] : header;
  if (!expected || typeof given !== 'string') return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

// Initialize Firebase Admin
initializeApp();

// Vertex AI configuration (from firebase_options.dart / .firebaserc)
const PROJECT_ID = 'ooinkai';
const LOCATION = 'us-central1';
const MODEL = 'text-embedding-004';
const ENDPOINT = `projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${MODEL}`;

// The Vertex client is created once per function instance and reused across
// invocations: building it per call opened a new gRPC channel (plus an auth
// token fetch) on every user turn. It is still required lazily so that
// getLiveKitToken, which shares this module via index.js, does not pay the
// @google-cloud/aiplatform load on its cold start.
let vertex = null;
// Flips after the first successful embed on this instance (for cold-start tagging).
let warmInstance = false;
function getVertex() {
  if (!vertex) {
    const aiplatform = require('@google-cloud/aiplatform');
    const {PredictionServiceClient} = aiplatform.v1;
    vertex = {
      client: new PredictionServiceClient({
        apiEndpoint: `${LOCATION}-aiplatform.googleapis.com`,
      }),
      helpers: aiplatform.helpers,
    };
  }
  return vertex;
}

/**
 * Generates embeddings using Vertex AI text-embedding-004 model

 * @param {Object} request - The request object containing data.text
 * @param {Object} context - The context object with auth information
 * @returns {Promise<Array<number>>} - The embedding vector (768 dimensions)
 */
const generateEmbedding = onCall(
  {
    region: 'us-central1',
    memory: '512MiB',
    // A full vCPU during requests: with the fractional CPU that comes with
    // 512MiB, the lazy @google-cloud/aiplatform load took ~40 s on a cold start
    // (observed 2026-09-24), far past the agent's 3 s embed timeout. Billed only
    // while a request is running.
    cpu: 1,
    timeoutSeconds: 45,
    maxInstances: 10,
    cors: true,
    consumeAppCheckToken: false,  // Disable App Check validation
    secrets: [EMBED_SHARED_SECRET],
  },
  async (request) => {
    console.log('🚀 Cloud Function triggered - generateEmbedding');

    if (!isAuthorizedCaller(request)) {
      console.error('❌ Missing or invalid x-ooink-embed-key');
      throw new HttpsError('unauthenticated', 'Missing or invalid embed key');
    }

    const {text} = request.data;            // Extract text from request
    // Customer speech: log its size only, never its content.
    console.log(`📝 Received text (length: ${text?.length})`);

    if (!text || typeof text !== 'string') {
      console.error('❌ Invalid text parameter');
      throw new HttpsError(
        'invalid-argument',
        'Text parameter is required and must be a string'
      );
    }

    // Prevent abuse - limit text length (embeddings work best with shorter text)
    if (text.length > 10000) {
      console.error(`❌ Text too long: ${text.length} chars`);
      throw new HttpsError(
        'invalid-argument',
        'Text is too long. Maximum 10,000 characters allowed.'
      );
    }

    try {
      // Reused per instance; ADC uses the Cloud Function's service account.
      const {client, helpers} = getVertex();
      const model = MODEL;
      const endpoint = ENDPOINT;
      console.log(`⚙️  Config - Project: ${PROJECT_ID}, Location: ${LOCATION}, Model: ${MODEL}`);

      // Prepare the prediction request using helpers.toValue() for protobuf format
      // IMPORTANT: task_type is REQUIRED for text-embedding-004 model
      // Options: RETRIEVAL_QUERY (for search queries), RETRIEVAL_DOCUMENT (for documents),
      //          SEMANTIC_SIMILARITY, CLASSIFICATION, CLUSTERING, QUESTION_ANSWERING, etc.
      const instance = {
        content: text,
        task_type: 'RETRIEVAL_QUERY',  // User queries for searching menu
      };
      const instances = [helpers.toValue(instance)];
      console.log('📨 Preparing prediction request with task_type: RETRIEVAL_QUERY (using protobuf format)');

      // Make the prediction request
      console.log('⏳ Calling Vertex AI API...');
      const vertexStarted = Date.now();
      const [response] = await client.predict({
        endpoint,
        instances,
      });
      console.log('✅ Received response from Vertex AI');
      // Structured timing so Vertex API time can be separated from instance cold
      // start (Cloud Run's request latency covers the whole invocation).
      console.log(JSON.stringify({
        event: 'embed_timing',
        vertex_ms: Date.now() - vertexStarted,
        cold: !warmInstance,
      }));
      warmInstance = true;

      // Extract embedding from response
      console.log(`🔍 Processing response... Predictions count: ${response.predictions?.length}`);
      if (!response.predictions || response.predictions.length === 0) {
        console.error('❌ No predictions in response');
        throw new Error('No predictions returned from Vertex AI');
      }

      const prediction = response.predictions[0];
      console.log('🔍 Prediction structure keys:', Object.keys(prediction || {}));

      // Extract embedding based on API response format
      // The response structure is: predictions[0].embeddings.values
      let embedding;

      if (prediction.embeddings && prediction.embeddings.values) {
        // Direct format
        console.log('✅ Using direct format (embeddings.values)');
        embedding = prediction.embeddings.values;
      } else if (prediction.structValue) {
        // Struct format - extract from nested structure
        console.log('🔄 Using struct format (structValue)');
        const embeddingStruct = prediction.structValue?.fields?.embeddings;
        const valuesStruct = embeddingStruct?.structValue?.fields?.values;
        const valuesList = valuesStruct?.listValue?.values;

        if (!valuesList) {
          console.error('❌ Response structure keys:', Object.keys(prediction || {}));
          throw new Error('Unexpected response format from Vertex AI');
        }

        embedding = valuesList.map((v) => v.numberValue);
      } else {
        console.error('❌ Response structure keys:', Object.keys(prediction || {}));
        throw new Error('Unexpected response format from Vertex AI');
      }

      console.log(`📏 Embedding extracted, length: ${embedding.length}`);

      // Validate embedding dimensions (should be 768 for text-embedding-004)
      if (embedding.length !== 768) {
        console.error(`❌ Invalid dimensions: ${embedding.length}`);
        throw new Error(
          `Invalid embedding dimensions: expected 768, got ${embedding.length}`
        );
      }

      console.log('✅ Embedding validated and ready to return');
      // Return embedding vector
      return {
        embedding,
        model: model,
        dimensions: embedding.length,
      };
    } catch (error) {
      // Log comprehensive error details for debugging (visible in Cloud Functions logs)
      console.error('❌❌❌ ERROR GENERATING EMBEDDING ❌❌❌');
      console.error('Error type:', error.constructor.name);
      console.error('Error code:', error.code);
      console.error('Error message:', error.message);
      console.error('Error details:', error.details);
      console.error('Error keys:', Object.keys(error || {}));
      console.error('Stack trace:', error.stack);  // server-side logs only, never returned

      // Return appropriate error to client
      if (error.code === 'PERMISSION_DENIED' || error.code === 7) {
        console.error('🚫 Permission denied - check service account roles');
        throw new HttpsError(
          'permission-denied',
          'Service account lacks permissions to access Vertex AI. ' +
            'Ensure the Cloud Functions service account has the Vertex AI User role.'
        );
      } else if (error.code === 'RESOURCE_EXHAUSTED' || error.code === 8) {
        console.error('⚠️ Resource exhausted - quota exceeded');
        throw new HttpsError(
          'resource-exhausted',
          'Vertex AI quota exceeded. Please try again later.'
        );
      } else if (error.code === 3 || error.code === 'INVALID_ARGUMENT') {
        console.error('❌ Invalid argument - check request format');
        throw new HttpsError(
          'invalid-argument',
          'Invalid request format for Vertex AI embedding API. Check task_type and content format.'
        );
      } else if (error.message?.includes('API has not been used')) {
        console.error('🔧 API not enabled');
        throw new HttpsError(
          'failed-precondition',
          'Vertex AI API is not enabled. Please enable it in Google Cloud Console.'
        );
      } else {
        console.error('💥 Unknown error - returning internal error to client');
        // Generic message only: the raw Vertex/gRPC message and stack stay in Cloud Logging.
        throw new HttpsError('internal', 'Failed to generate embedding');
      }
    }
  }
);

module.exports = { generateEmbedding };