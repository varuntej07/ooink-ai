// Backend proxy server for OpenAI API calls to keep the API key secure on the server side

const express = require('express');
const cors = require('cors');
require('dotenv').config();

const { spawn } = require('child_process');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());        // Middleware: Allows cross-origin requests
app.use(express.json());

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', message: 'Ooink backend is running!' });
});

// OpenAI proxy endpoint with RAG
app.post('/api/chat', async (req, res) => {
  try {
    const { message } = req.body;

    // Validate request
    if (!message || typeof message !== 'string') {
      return res.status(400).json({ error: 'Message is required and must be a string' });
    }

    // Call Python RAG function
    const pythonProcess = spawn('python', [path.join(__dirname, 'rag.py'), message]);

    let aiResponse = '';
    let errorOutput = '';

    pythonProcess.stdout.on('data', (data) => {
      aiResponse += data.toString();
    });

    pythonProcess.stderr.on('data', (data) => {
      errorOutput += data.toString();
      console.error('Python error:', data.toString());
    });

    pythonProcess.on('close', (code) => {
      if (code !== 0) {
        console.error('Python script failed:', errorOutput);
        return res.status(500).json({ error: 'RAG processing failed' });
      }

      const response = aiResponse.trim();
      res.json({ response: response || "Oink! I couldn't find an answer, try asking differently!" });
    });

  } catch (error) {
    console.error('Server error:', error);
    res.status(500).json({
      error: 'Internal server error',
      message: error.message
    });
  }
});

// Start server
app.listen(PORT, () => {
  console.log(`🐷 Ooink backend running on port ${PORT}`);
  console.log(`API key configured: ${process.env.OPENAI_API_KEY ? 'Yes ✓' : 'No ✗'}`);
});
