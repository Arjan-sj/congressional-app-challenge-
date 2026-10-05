# Congressional App Challenge Project

A Flutter-based application being developed for the Congressional App Challenge.

## Tech Stack

- **Framework:** Flutter
- **Language:** Dart
- **UI:** Material 3
- **Platforms:** iOS, Android, Web, Windows, macOS, and Linux

Flutter was selected because it allows the application to share one codebase across multiple platforms while keeping the interface responsive and consistent.

## Current Features

The current build provides the base structure of the application, including:

- Home screen
- Multi-screen navigation
- Prototype feature screen
- About/project information screen
- Reusable UI components
- Basic application state
- Material 3 theme

The main functionality of the app will be built on top of this structure.

## Project Structure

```text
lib/
├── main.dart
├── screens/
│   ├── home_screen.dart
│   ├── prototype_screen.dart
│   └── about_screen.dart
└── widgets/
    └── feature_card.dart
```

### `main.dart`

Initializes the application, theme, and starting screen.

### `screens/`

Contains the main pages of the application.

### `widgets/`

Contains reusable interface components that can be shared across multiple screens.

## Getting Started

### Requirements

Install Flutter and verify the installation with:

```bash
flutter doctor
```

### Install Dependencies

From the project directory:

```bash
flutter pub get
```

### Run the App

Run on a connected device or emulator:

```bash
flutter run
```

Run in Chrome:

```bash
flutter run -d chrome
```

## Development

The main feature of the application is currently being developed in:

```text
lib/screens/prototype_screen.dart
```

As the project expands, additional folders may be added for application logic, data models, APIs, and other services.

A possible future structure is:

```text
lib/
├── models/
├── screens/
├── services/
├── utils/
└── widgets/
```

## Version Control

The project can be initialized as a Git repository with:

```bash
git init
git add .
git commit -m "Initial app structure"
```

## Status

**In Development**

The current version establishes the application's base architecture and interface. Core functionality and project-specific features will be added throughout development.
