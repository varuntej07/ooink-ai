#!/usr/bin/env python3
"""
Offline script to generate embeddings for the Ooink menu knowledge base.
Run this script ONLY when the menu knowledge base changes.

Requirements:
    pip install google-cloud-aiplatform

Setup:
    1. Install Google Cloud SDK: https://cloud.google.com/sdk/docs/install
    2. Authenticate: gcloud auth application-default login
    3. Set project: gcloud config set project ooinkai

Usage:
    python scripts/generate_embeddings.py
"""

import json
import os
from datetime import datetime
from typing import List, Dict, Any

try:
    from vertexai.language_models import TextEmbeddingModel
    import vertexai
except ImportError:
    exit(1)


def create_semantic_chunks(menu_data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Creates semantic chunks from the menu knowledge base.
    Each chunk is a self-contained piece of information with metadata.

    How it chunks:
    - Each menu item = 1 chunk (includes name, description, allergens, reviews, etc.)
    - Each FAQ = 1 chunk (question + answer together)
    - Restaurant info = 1 chunk (general restaurant information)
    """
    chunks = []

    # Chunk 1: Restaurant information (general context)
    if 'restaurant_info' in menu_data:
        restaurant_info = menu_data['restaurant_info']
        text_parts = [
            f"Restaurant: {restaurant_info.get('name', '')}",
            f"Cuisine: {restaurant_info.get('cuisine_type', '')}",
            f"Philosophy: {restaurant_info.get('philosophy', '')}",
            f"Story: {restaurant_info.get('brand_story', '')}",
        ]

        # Add location information
        if 'locations' in restaurant_info:
            for location in restaurant_info['locations']:
                text_parts.extend([
                    f"\nLocation: {location.get('location_name', '')}",
                    f"Address: {location.get('address', '')}",
                    f"Phone: {location.get('phone', '')}",
                    f"Hours: {location.get('hours', '')}",
                ])

        chunks.append({
            'id': 'restaurant_info',
            'text': '\n'.join(text_parts),
            'metadata': {
                'type': 'restaurant_info',
                'category': 'general',
            },
        })

    # Chunk menu items: Each menu item becomes its own chunk
    if 'menu_categories' in menu_data:
        for category in menu_data['menu_categories']:
            category_name = category.get('category', '')
            items = category.get('items', [])

            for item in items:
                text_parts = [f"Category: {category_name}"]
                text_parts.append(f"Name: {item.get('name', '')}")

                if 'also_known_as' in item:
                    text_parts.append(f"Also known as: {item['also_known_as']}")
                if 'price' in item:
                    text_parts.append(f"Price: {item['price']}")
                if 'description' in item:
                    text_parts.append(f"Description: {item['description']}")
                if 'flavor_profile' in item:
                    text_parts.append(f"Flavor: {item['flavor_profile']}")
                if 'spice_level' in item:
                    text_parts.append(f"Spice level: {item['spice_level']}")
                if 'dietary_options' in item:
                    text_parts.append(f"Dietary options: {item['dietary_options']}")
                if 'allergens' in item:
                    text_parts.append(f"Allergens: {item['allergens']}")
                if 'best_for' in item:
                    text_parts.append(f"Best for: {item['best_for']}")
                if 'review_highlights' in item:
                    reviews = ', '.join(item['review_highlights'])
                    text_parts.append(f"Reviews: {reviews}")

                chunks.append({
                    'id': item.get('id', f'item_{len(chunks)}'),
                    'text': '\n'.join(text_parts),
                    'metadata': {
                        'type': 'menu_item',
                        'category': category_name,
                        'name': item.get('name', ''),
                    },
                })

    # Chunk FAQs: Each Q&A pair becomes one chunk
    if 'common_customer_questions' in menu_data:
        for i, qa in enumerate(menu_data['common_customer_questions']):
            text = f"Question: {qa.get('question', '')}\nAnswer: {qa.get('answer', '')}"

            chunks.append({
                'id': f'faq_{i}',
                'text': text,
                'metadata': {
                    'type': 'faq',
                    'question': qa.get('question', ''),
                },
            })

    return chunks


def main():
    print("[Ooink] Embedding Generator - Starting...\n")

    # Project configuration
    PROJECT_ID = "ooinkai"  # From firebase_options.dart
    LOCATION = "us-central1"  # Default Vertex AI location
    MODEL_NAME = "text-embedding-004"

    # File paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    kb_path = os.path.join(project_root, 'assets', 'menu_knowledge_base_json.txt')
    output_path = os.path.join(project_root, 'assets', 'menu_embeddings.json')

    try:
        # Initialize Vertex AI
        print(f"[Init] Initializing Vertex AI (project: {PROJECT_ID}, location: {LOCATION})...")
        vertexai.init(project=PROJECT_ID, location=LOCATION)
        model = TextEmbeddingModel.from_pretrained(MODEL_NAME)
        print("[OK] Vertex AI initialized\n")

        # Read menu knowledge base
        print(f"[Load] Reading menu knowledge base from {kb_path}...")
        if not os.path.exists(kb_path):
            raise FileNotFoundError(f"Knowledge base not found at {kb_path}")

        with open(kb_path, 'r', encoding='utf-8') as f:
            menu_data = json.load(f)

        print("[OK] Knowledge base loaded\n")

        # Create semantic chunks
        print("[Chunk] Creating semantic chunks...")
        chunks = create_semantic_chunks(menu_data)
        print(f"[OK] Created {len(chunks)} chunks\n")

        # Generate embeddings
        print(f"[Embed] Generating embeddings for {len(chunks)} chunks using {MODEL_NAME}...")
        embeddings_output = []

        for i, chunk in enumerate(chunks):
            print(f"  Processing chunk {i + 1}/{len(chunks)}: {chunk['id']}")

            try:
                # Call Vertex AI API to generate embedding
                embeddings = model.get_embeddings([chunk['text']])
                embedding_vector = embeddings[0].values

                embeddings_output.append({
                    'id': chunk['id'],
                    'text': chunk['text'],
                    'embedding': embedding_vector,
                    'metadata': chunk['metadata'],
                })

                print(f"    [OK] Embedded ({len(embedding_vector)} dimensions)")

            except Exception as e:
                print(f"    [ERROR] Failed: {e}")
                raise

        print("\n[OK] All embeddings generated!\n")

        # Save embeddings to JSON
        print(f"[Save] Saving embeddings to {output_path}...")
        output_data = {
            'model': MODEL_NAME,
            'dimension': len(embeddings_output[0]['embedding']) if embeddings_output else 768,
            'generated_at': datetime.now().isoformat(),
            'total_chunks': len(embeddings_output),
            'chunks': embeddings_output,
        }

        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(output_data, f, indent=2)

        file_size = os.path.getsize(output_path) / 1024  # KB
        print(f"[OK] Saved to {output_path} ({file_size:.2f} KB)\n")

        print("[SUCCESS] Embedding generation complete!")
        print(f"[Summary] {len(embeddings_output)} chunks, {output_data['dimension']} dimensions each")
        print("[Ready] You can now run the app - embeddings will load instantly!\n")

    except Exception as e:
        print(f"\n[ERROR] Error generating embeddings:")
        print(f"   {e}")
        import traceback
        traceback.print_exc()
        exit(1)


if __name__ == '__main__':
    main()
