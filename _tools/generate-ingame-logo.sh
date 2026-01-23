#!/usr/bin/env bash
# Script to generate in-game WoW icons for HideBattleNetFriends
# Generates 32x32 TGA, 64x64 TGA

# --- CONFIG ---
SRC_LOGO="../Screenshots/logo.png"
DEST_DIR="../HideBattleNetFriends/Logo"
LOGO32_TGA="$DEST_DIR/HideBattleNetFriends32.tga"
LOGO64_TGA="$DEST_DIR/HideBattleNetFriends64.tga"

# --- Checks ---
if [ ! -f "$SRC_LOGO" ]; then
    echo "Error: source file $SRC_LOGO not found"
    exit 1
fi

# Create destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# --- Generate 32x32 TGA ---
echo "Generating 32x32 TGA..."
magick "$SRC_LOGO" -resize 32x32! -filter point "$LOGO32_TGA"

# --- Generate 64x64 TGA ---
echo "Generating 64x64 TGA..."
magick "$SRC_LOGO" -resize 64x64! -filter point "$LOGO64_TGA"

echo "✅ Generation completed!"
echo "Files available in $DEST_DIR:"
ls -lh "$DEST_DIR"
