import json
import numpy as np
from sentence_transformers import SentenceTransformer
from openai import OpenAI
import os
from dotenv import load_dotenv

load_dotenv('../.env')

# Init
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
model = SentenceTransformer('all-MiniLM-L6-v2')

# Load embeddings
with open('ooink_embeddings.json', 'r', encoding='utf-8') as f:
    chunks = json.load(f)['chunks']


def ask(question):
    # Embed question
    q_vec = model.encode(question)

    # Find similar chunks
    # similarity = (A · B) / (||A|| × ||B||)
    scores = [(c['text'], np.dot(q_vec, c['embedding']) / (np.linalg.norm(q_vec) * np.linalg.norm(c['embedding'])))
              for c in chunks]
    scores.sort(key=lambda x: x[1], reverse=True)

    # Get top 5
    context = "\n\n".join([s[0] for s in scores[:5]])

    # Ask OpenAI
    response = client.chat.completions.create(
        model="gpt-3.5-turbo",
        messages=[
            {"role": "system", "content": "You are Pig, the AI assistant at Ooink Ramen Fremont. Answer using ONLY the context provided. Be friendly!"},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {question}"}
        ],
        temperature=0.7,
        max_tokens=200
    )

    return response.choices[0].message.content

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        question = sys.argv[1]
        print(ask(question))
    else:
        print("No question provided")