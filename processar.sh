#!/usr/bin/env bash
# processar.sh — converte wallpapers novos pra WebP, gera prévias e sobe pro GitHub.
#
# Estrutura do repositório:
#   wallpapers/
#   ├── adicionar wallpapers/  <- solta as imagens novas aqui (fica fora do git)
#   │   └── falhou/            <- imagens que deram erro ao tratar (confere na mão)
#   ├── imagens/               <- versão final em WebP, com nome único (vai pro git)
#   ├── previas/               <- miniaturas da galeria do README (vai pro git)
#   ├── README.md              <- a galeria (entre os marcadores) é gerada pelo script
#   └── processar.sh
#
# Dependências (Debian/Ubuntu):
#   sudo apt install imagemagick

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
ENTRADA="$REPO/adicionar wallpapers"
FALHOU="$ENTRADA/falhou"
SAIDA="$REPO/imagens"
PREVIAS="$REPO/previas"

QUALIDADE="${QUALIDADE:-90}"   # WebP com perda; 90 é visualmente igual ao original em wallpaper
MAX_LADO=3840                  # reduz o que passar de 4K; 0 desliga
PREVIA="480x270"               # miniatura 16:9 da galeria do README
IDADE_MIN="${IDADE_MIN:-2}"    # só pega arquivo parado há N+ min (evita pegar cópia pela metade)

# Impede duas execuções ao mesmo tempo
if command -v flock >/dev/null; then
  exec 9>"$REPO/.processar.lock"
  flock -n 9 || { echo "Já tem uma execução rodando, saindo."; exit 0; }
fi

mkdir -p "$ENTRADA" "$FALHOU" "$SAIDA" "$PREVIAS"
cd "$REPO"

git pull --rebase --quiet || echo "Aviso: git pull falhou, seguindo assim mesmo."

novas=0
duplicadas=0
falhas=0
economia=0

falhou() {
  echo "ERRO ao tratar $nome ($1), movido pra adicionar wallpapers/falhou/"
  mv -f "$arq" "$FALHOU/"
  falhas=$((falhas + 1))
}

# Converte pra WebP numa etapa só: gira foto de celular (EXIF), reduz, tira metadados e codifica.
# Pra PNG (desenho, arte chapada) testa também sem perda e fica com o menor.
converter() {
  local origem="$1" destino="$2" formato="$3"
  local redim=()
  (( MAX_LADO > 0 )) && redim=(-resize "${MAX_LADO}x${MAX_LADO}>")

  magick "${origem}[0]" -auto-orient "${redim[@]}" -strip \
    -quality "$QUALIDADE" -define webp:method=6 "$destino" || return 1

  if [[ "$formato" == "PNG" ]]; then
    local sem_perda="${destino%.webp}.ll.webp"
    if magick "${origem}[0]" -auto-orient "${redim[@]}" -strip \
         -define webp:lossless=true -define webp:method=6 "$sem_perda"; then
      if (( $(stat -c %s "$sem_perda") < $(stat -c %s "$destino") )); then
        mv -f "$sem_perda" "$destino"
      fi
    fi
    rm -f "$sem_perda"
  fi
}

gerar_previa() {
  magick "$1" -resize "${PREVIA}^" -gravity center -extent "$PREVIA" \
    -strip -quality 75 "$2"
}

# Recebe hashes (um por linha) e monta as miniaturas clicáveis (HTML funciona no Markdown do GitHub)
miniaturas() {
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    printf '<a href="imagens/%s.webp"><img src="previas/%s.webp" width="240" alt="%s"></a>\n' "$h" "$h" "$h"
  done
}

# Reescreve a galeria do README (trecho entre os marcadores), mais recentes primeiro.
# A ordem vem da própria galeria: as novas entram no topo. (Data de arquivo não serve:
# se perde ao clonar o repo em outra máquina.) Some da lista o que não existe mais em imagens/.
novos_hashes=()
atualizar_galeria() {
  local lista total bloco
  lista="$(
    {
      for (( i=${#novos_hashes[@]}-1; i>=0; i-- )); do echo "${novos_hashes[i]}"; done
      sed -n '/<!-- galeria:inicio -->/,/<!-- galeria:fim -->/p' README.md \
        | sed -n 's|^<a href="imagens/\([0-9a-f]*\)\.webp".*|\1|p'
      # Imagem que está em imagens/ mas sumiu da galeria (ex.: README editado na mão) vai pro fim
      find "$SAIDA" -maxdepth 1 -name '*.webp' -printf '%f\n' | sed 's/\.webp$//' | sort
    } | awk '!visto[$0]++' | while IFS= read -r h; do if [[ -f "$SAIDA/$h.webp" ]]; then echo "$h"; fi; done
  )"
  total="$(printf '%s\n' "$lista" | grep -c . || true)"
  bloco="$(printf '%s\n' "$lista" | miniaturas)"

  # Passa pelo ambiente (ENVIRON): awk -v interpretaria barras invertidas
  BLOCO="$bloco" TOTAL="$total" awk '
    /<!-- galeria:inicio -->/ {
      print; print ""
      print ENVIRON["TOTAL"] " wallpapers, mais recentes primeiro. Clica na miniatura pra abrir a imagem inteira."
      print ""; print ENVIRON["BLOCO"]; dentro=1; next
    }
    /<!-- galeria:fim -->/ { print ""; dentro=0 }
    !dentro { print }
  ' README.md > README.md.tmp && mv README.md.tmp README.md
}

while IFS= read -r -d '' arq; do
  nome="$(basename "$arq")"

  # Formato real, lido do cabeçalho do arquivo (a extensão pode mentir: PNG salvo como .jpg, etc.)
  formato="$(identify -ping -format '%m' "${arq}[0]" 2>/dev/null)" || { falhou "arquivo ilegível"; continue; }
  case "$formato" in
    JPEG|PNG|WEBP) ;;
    *) falhou "formato real $formato não suportado"; continue ;;
  esac

  # Nome = hash do conteúdo ORIGINAL -> nunca sobrescreve e detecta repetida
  hash="$(sha256sum "$arq" | cut -c1-12)"
  destino="$SAIDA/$hash.webp"

  if [[ -e "$destino" ]]; then
    echo "Repetida (já existe como $hash.webp): $nome"
    rm -f "$arq"
    duplicadas=$((duplicadas + 1))
    continue
  fi

  antes=$(stat -c %s "$arq")
  tmp="$(mktemp --suffix=.webp)"

  if ! converter "$arq" "$tmp" "$formato" || ! gerar_previa "$tmp" "$PREVIAS/$hash.webp"; then
    rm -f "$tmp" "$PREVIAS/$hash.webp"
    falhou "erro na conversão"
    continue
  fi

  depois=$(stat -c %s "$tmp")
  mv "$tmp" "$destino"
  chmod 644 "$destino" "$PREVIAS/$hash.webp"
  rm -f "$arq"

  economia=$((economia + antes - depois))
  novas=$((novas + 1))
  novos_hashes+=("$hash")
  printf '%-40s -> %s.webp  (%d KB -> %d KB)\n' "$nome" "$hash" $((antes/1024)) $((depois/1024))
done < <(find "$ENTRADA" -maxdepth 1 -type f -mmin +"$IDADE_MIN" \
           \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0)

if (( novas + duplicadas + falhas > 0 )); then
  echo "$(date '+%Y-%m-%d %H:%M') | Novas: $novas | Repetidas: $duplicadas | Falhas: $falhas | Economia: $((economia/1024/1024)) MB"
fi

if (( novas > 0 )); then
  atualizar_galeria
  git add imagens/ previas/ README.md
  git commit --quiet -m "wallpapers: +$novas ($(date '+%Y-%m-%d %H:%M'))"
fi

# Empurra qualquer commit pendente (inclusive de execução anterior que ficou sem rede)
if [[ -n "$(git log '@{u}..' --oneline 2>/dev/null)" ]]; then
  if git push --quiet; then
    echo "Enviado pro GitHub."
  else
    echo "Aviso: git push falhou; tenta de novo na próxima execução."
  fi
fi
