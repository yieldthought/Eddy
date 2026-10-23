#!/bin/bash
# Install Eddy.app and the ~/bin/eddy terminal launcher (quit Eddy first).
# Pass --icon to redraw the app icon while building.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -d "$HOME/bin/eddy" ]]; then
  echo "$HOME/bin/eddy is a directory; move it aside before installing." >&2
  exit 1
fi

./build.sh --install "$@"

mkdir -p "$HOME/bin"
launcher="$(mktemp "$HOME/bin/.eddy.XXXXXX")"
trap 'rm -f "$launcher"' EXIT
cat > "$launcher" <<'EOF'
#!/bin/sh
exec /usr/bin/open -a /Applications/Eddy.app "$@"
EOF
chmod 755 "$launcher"
mv -f "$launcher" "$HOME/bin/eddy"
echo "Installed $HOME/bin/eddy"

case ":${PATH:-}:" in
  *":$HOME/bin:"*) ;;
  *)
    echo 'To run eddy by name, add this line to your shell startup file (usually ~/.zshrc):'
    echo 'export PATH="$HOME/bin:$PATH"'
    ;;
esac
