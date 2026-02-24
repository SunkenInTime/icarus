#!/bin/bash
# Linux environment setup for Icarus Flutter app
# This script ensures the required XDG user directories are configured
# which are needed by the path_provider Flutter plugin

echo "Setting up Linux environment for Icarus..."

# Install xdg-user-dirs if not present
if ! command -v xdg-user-dir &> /dev/null; then
    echo "Installing xdg-user-dirs..."
    sudo apt-get update && sudo apt-get install -y xdg-user-dirs
fi

# Initialize XDG user directories
echo "Initializing XDG user directories..."
xdg-user-dirs-update

# Create required directories
mkdir -p "$HOME/.local/share/icarus"
mkdir -p "$HOME/.cache/icarus"
mkdir -p "$HOME/.config"

echo "Linux environment setup complete!"
echo "You can now run the app with: fvm flutter run -d linux"
echo "Or directly run the binary: ./build/linux/x64/debug/bundle/icarus"
