# Linux Environment Setup

## Issue
The Icarus Flutter app on Linux requires XDG user directories to be properly configured. Without the `xdg-user-dirs` package installed and initialized, the app will fail to start with:
```
MissingPlatformDirectoryException(Unable to get application documents directory)
```

## Solution
The app requires the `xdg-user-dirs` package to be installed on Linux systems. This package provides the standard XDG user directories that Flutter's `path_provider` plugin depends on.

### Setup
Run the setup script before first launch:
```bash
./setup_linux_env.sh
```

Or manually:
```bash
# Install required package
sudo apt-get update && sudo apt-get install -y xdg-user-dirs

# Initialize user directories
xdg-user-dirs-update

# Create app directories
mkdir -p ~/.local/share/icarus
mkdir -p ~/.cache/icarus
mkdir -p ~/.config
```

### Running the App
After setup, run the app normally:
```bash
fvm flutter run -d linux
```

Or run the compiled binary directly:
```bash
./build/linux/x64/debug/bundle/icarus
```

## Technical Details
- Flutter's `path_provider` plugin uses the `xdg_user` C library on Linux
- This library requires XDG user directories to be configured
- The `xdg-user-dirs` package provides the utilities to set these up
- Without it, calls to `getApplicationSupportDirectory()` and `getApplicationDocumentsDirectory()` will fail
