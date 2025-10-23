# Ooink AI Kiosk

AI-powered menu assistant for Ooink Ramen Restaurant. Helps customers learn about the menu while they wait outside during busy hours.

## Overview

A Flutter kiosk app featuring an animated AI pig that answers customer questions about menu items, ingredients, and specialties through voice interaction.

## Architecture

- **MVVM Pattern**: Strict separation between Views, ViewModels, and business logic
- **Provider**: State management using ChangeNotifierProvider
- **Services**: Speech-to-text, OpenAI API integration, text-to-speech

## Tech Stack

- Flutter 3.9+
- OpenAI API (GPT models)
- Speech-to-text recognition
- Flutter TTS
- Lottie animations

## Setup

Create a `.env` file in the root directory:
```
OPENAI_API_KEY=your_openai_api_key_here
```

Run the app:
```bash
flutter pub get
flutter run
```

## Key Features

- Voice-activated conversation interface
- Real-time speech recognition
- AI-powered menu recommendations
- Animated pig mascot (Lottie)
- Kiosk mode for unattended operation
