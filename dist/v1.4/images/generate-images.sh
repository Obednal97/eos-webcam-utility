#!/bin/bash
# Generates the placeholder images for EOS Webcam Utility
# Looks for logo.png or logo.svg in the same directory for overlay

DIR="$(cd "$(dirname "$0")" && pwd)"
LOGO=""
LOGO_ARGS=""

# Find logo file
if [ -f "$DIR/logo.png" ]; then
    LOGO="$DIR/logo.png"
elif [ -f "$DIR/logo.svg" ]; then
    LOGO="$DIR/logo.svg"
fi

# Generate "Connecting" image
if [ -n "$LOGO" ]; then
    echo "Using logo: $LOGO"
    # Resize logo to fit within 500x250 box, maintain aspect ratio
    # Composite logo centered above the text
    magick -size 1980x1080 xc:'#1a1a1a' \
      -fill '#2a2a2a' -draw "polygon 300,0 1980,0 1980,900 600,1080 0,1080 0,200" \
      -fill '#222222' -draw "polygon 400,0 1980,0 1980,800 700,1080 100,1080 0,300" \
      -fill '#1a1a1a' -draw "polygon 500,0 1980,100 1980,700 800,1080 200,1080 0,400" \
      \( "$LOGO" -resize 500x250 -background none -gravity center -extent 500x250 \) \
      -gravity center -geometry +0-140 -composite \
      -fill '#cccccc' -font Helvetica -pointsize 72 -gravity center \
      -annotate +0+60 "Connecting to camera..." \
      -fill '#4a9eff' -pointsize 48 \
      -annotate +0+140 "Please wait" \
      -quality 92 "$DIR/errorNoDevice_connecting.jpg"
    echo "Created connecting image (with logo)"
else
    echo "No logo found — generating without logo"
    magick -size 1980x1080 xc:'#1a1a1a' \
      -fill '#2a2a2a' -draw "polygon 300,0 1980,0 1980,900 600,1080 0,1080 0,200" \
      -fill '#222222' -draw "polygon 400,0 1980,0 1980,800 700,1080 100,1080 0,300" \
      -fill '#1a1a1a' -draw "polygon 500,0 1980,100 1980,700 800,1080 200,1080 0,400" \
      -fill '#cccccc' -font Helvetica -pointsize 72 -gravity center \
      -annotate +0-40 "Connecting to camera..." \
      -fill '#4a9eff' -pointsize 48 \
      -annotate +0+60 "Please wait" \
      -quality 92 "$DIR/errorNoDevice_connecting.jpg"
    echo "Created connecting image (no logo)"
fi

# Generate "Disconnected" image (same style, no logo needed)
magick -size 1980x1080 xc:'#1a1a1a' \
  -fill '#2a2a2a' -draw "polygon 300,0 1980,0 1980,900 600,1080 0,1080 0,200" \
  -fill '#222222' -draw "polygon 400,0 1980,0 1980,800 700,1080 100,1080 0,300" \
  -fill '#1a1a1a' -draw "polygon 500,0 1980,100 1980,700 800,1080 200,1080 0,400" \
  -fill '#ff4444' -font Helvetica-Bold -pointsize 72 -gravity center \
  -annotate +0-40 "Camera not connected" \
  -fill '#888888' -font Helvetica -pointsize 48 \
  -annotate +0+60 "Please connect your camera via USB" \
  -quality 92 "$DIR/errorNoDevice_disconnected.jpg"
echo "Created disconnected image"

echo "Done. Images at:"
ls -la "$DIR"/errorNoDevice_*.jpg
