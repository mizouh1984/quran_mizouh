name: Auto Build IPK & Release Quran Mizouh

on:
  push:
    branches:
      - main
    paths:
      - 'version.json'
      - 'enigma2-plugin-extensions-quranmizouh.tar.gz'
      - 'install_quran_mizouh_allinone.sh'

permissions:
  contents: write

jobs:
  build-and-release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Read version and changelog from version.json
        id: meta
        run: |
          VERSION=$(jq -r '.version' version.json | sed 's/^v//')
          TAG="v${VERSION}"
          CHANGELOG_AR=$(jq -r '.changelog_ar // ""' version.json)
          CHANGELOG_EN=$(jq -r '.changelog_en // ""' version.json)
          IPK_NAME="enigma2-plugin-extensions-quranmizouh_${VERSION}_all.ipk"

          echo "tag=${TAG}" >> "$GITHUB_OUTPUT"
          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
          echo "ipk_name=${IPK_NAME}" >> "$GITHUB_OUTPUT"

          {
            echo "body<<EOF"
            echo "### 📖 قارئ القرآن - mizouh المتميز (${TAG})"
            echo ""
            if [ -n "$CHANGELOG_AR" ]; then
              echo "**التحديثات (العربية):**"
              echo "${CHANGELOG_AR}"
              echo ""
            fi
            if [ -n "$CHANGELOG_EN" ]; then
              echo "**What's New (English):**"
              echo "${CHANGELOG_EN}"
              echo ""
            fi
            echo "---"
            echo "#### ⚡ أمر التثبيت السريع (Telnet / SSH):"
            echo '```sh'
            echo 'wget -q --no-check-certificate "[https://raw.githubusercontent.com/mizouh1984/quran_mizouh/main/install_quran_mizouh_allinone.sh](https://raw.githubusercontent.com/mizouh1984/quran_mizouh/main/install_quran_mizouh_allinone.sh)" -O - | /bin/sh'
            echo '```'
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Build .ipk package automatically
        run: |
          VERSION="${{ steps.meta.outputs.version }}"
          IPK_FILE="${{ steps.meta.outputs.ipk_name }}"
          mkdir -p build_ipk/CONTROL build_ipk/data

          # Extract plugin files from tar.gz into package data folder
          tar -xzf enigma2-plugin-extensions-quranmizouh.tar.gz -C build_ipk/data
          find build_ipk/data -type d -exec chmod 755 {} \;
          find build_ipk/data -type f -exec chmod 644 {} \;

          # Create standard Enigma2 IPK control file
          cat << EOF > build_ipk/CONTROL/control
          Package: enigma2-plugin-extensions-quranmizouh
          Version: ${VERSION}
          Section: misc
          Priority: optional
          Architecture: all
          Maintainer: mizouh1984
          Description: Quran Reader - mizouh Al-Mutamayiz for Enigma2
          EOF

          # Create postinst script for clean permissions
          cat << 'EOF' > build_ipk/CONTROL/postinst
          #!/bin/sh
          chmod -R 755 /usr/lib/enigma2/python/Plugins/Extensions/QuranMizouh 2>/dev/null || true
          exit 0
          EOF
          chmod 755 build_ipk/CONTROL/postinst

          # Assemble standard ar-based .ipk archive
          echo "2.0" > build_ipk/debian-binary
          tar --numeric-owner --owner=0 --group=0 -czf build_ipk/control.tar.gz -C build_ipk/CONTROL .
          tar --numeric-owner --owner=0 --group=0 -czf build_ipk/data.tar.gz -C build_ipk/data .
          (cd build_ipk && ar -r "../${IPK_FILE}" debian-binary control.tar.gz data.tar.gz)
          cp "${IPK_FILE}" "enigma2-plugin-extensions-quranmizouh.ipk"

      - name: Create or Update GitHub Release with .ipk & .tar.gz
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.meta.outputs.tag }}
          name: "قارئ القرآن - mizouh المتميز ${{ steps.meta.outputs.tag }}"
          body: ${{ steps.meta.outputs.body }}
          draft: false
          prerelease: false
          files: |
            ${{ steps.meta.outputs.ipk_name }}
            enigma2-plugin-extensions-quranmizouh.ipk
            enigma2-plugin-extensions-quranmizouh.tar.gz
            install_quran_mizouh_allinone.sh
