const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {initializeApp} = require('firebase-admin/app');

// Initialize Firebase Admin
initializeApp();

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
    timeoutSeconds: 45,
    maxInstances: 10,
    cors: true,
  },
  async (request) => {
    console.log('🚀 Cloud Function triggered - generateEmbedding');

    const {text} = request.data;            // Extract text from request
    console.log(`📝 Received text (length: ${text?.length}): "${text?.substring(0, 100)}..."`);

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
      console.log('📦 Loading Vertex AI client...');
      // Import Vertex AI client (dynamic import to reduce cold start time)
      const aiplatform = require('@google-cloud/aiplatform');
      const {PredictionServiceClient} = aiplatform.v1;
      const {helpers} = aiplatform;
      console.log('✅ Vertex AI client loaded');

      // Configuration from your firebase_options.dart
      const projectId = 'ooinkai';
      const location = 'us-central1';
      const model = 'text-embedding-004';
      console.log(`⚙️  Config - Project: ${projectId}, Location: ${location}, Model: ${model}`);

      // Initialize Vertex AI client with Application Default Credentials
      // ADC automatically uses the Cloud Function's service account
      const client = new PredictionServiceClient({
        apiEndpoint: `${location}-aiplatform.googleapis.com`,
      });
      console.log(`🔗 Vertex AI client initialized with endpoint: ${location}-aiplatform.googleapis.com`);

      // Build the endpoint path
      const endpoint = `projects/${projectId}/locations/${location}/publishers/google/models/${model}`;
      console.log(`📍 API Endpoint: ${endpoint}`);

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
      const [response] = await client.predict({
        endpoint,
        instances,
      });
      console.log('✅ Received response from Vertex AI');

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
          console.error('❌ Response structure:', JSON.stringify(prediction, null, 2));
          throw new Error('Unexpected response format from Vertex AI');
        }

        embedding = valuesList.map((v) => v.numberValue);
      } else {
        console.error('❌ Response structure:', JSON.stringify(prediction, null, 2));
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
      console.error('Full error:', JSON.stringify(error, null, 2));
      console.error('Stack trace:', error.stack);

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
        throw new HttpsError(
          'internal',
          `Failed to generate embedding: ${error.message}`,
          error.stack
        );
      }
    }
  }
);

module.exports = { generateEmbedding };