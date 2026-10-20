    echo "DL_DIR_B64='$(printf '%s' "${wizard_dl_dir:-}" | sed 's|/*$||' | base64 | tr -d '\n=' | tr '+/' '-_')'"
