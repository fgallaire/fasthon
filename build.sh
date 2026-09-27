#!/usr/bin/env bash
#
# Build Fasthon — CPython's parser frontend (tokenizer + PEG → AST) to WASM,
# a drop-in for Brython's JS parser. Strategy C: the parser keeps its own
# minimal ABI-correct str/bytes (shims/) and carries literals as source spans;
# the JS side rebuilds Brython AST objects. No eval loop, no object layer.
#
# Output: build/fasthon_mod.{js,wasm} (CommonJS, EXPORT_NAME=createFasthon) —
# used by the node harnesses (bench/validate/...) and loader/index.html.
#
# emsdk and the CPython 3.14.6 source live outside the repo, in ../external
# ($EMSDK / $CPYTHON_SRC override).
# The cross pyconfig.h is committed (cpy-build/pyconfig.h); regenerate via the
# emconfigure dance in BUILD_NOTES.md only if bumping the CPython version.
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
UP="$(cd "${REPO}/.." && pwd)"
# emsdk and the CPython source: ../external, next to this repo (what the CI
# stages), else ../wasthon4/external (a dev checkout next door).
EXT="${UP}/external"
[ -d "${EXT}" ] || [ ! -d "${UP}/wasthon4/external" ] || EXT="${UP}/wasthon4/external"
CPY="${CPYTHON_SRC:-${EXT}/Python-3.14.6}"
EMSDK="${EMSDK:-${EXT}/emsdk}"
OUT="${REPO}/build"
mkdir -p "${OUT}"
source "${EMSDK}/emsdk_env.sh" >/dev/null 2>&1

INC="-I ${REPO}/cpy-build -I ${CPY}/Include -I ${CPY}/Include/internal -I ${CPY}/Include/internal/mimalloc -I ${CPY} -I ${CPY}/Parser -I ${CPY}/Objects"
CF="-O2 -DPy_BUILD_CORE -fno-strict-aliasing ${INC}"

# CPython parser frontend translation units (frontend only — no interpreter).
PARSER_TUS=(
  Parser/pegen.c Parser/parser.c Parser/pegen_errors.c Parser/string_parser.c
  Parser/action_helpers.c Parser/token.c
  Parser/lexer/lexer.c Parser/lexer/buffer.c Parser/lexer/state.c
  Parser/tokenizer/string_tokenizer.c Parser/tokenizer/utf8_tokenizer.c Parser/tokenizer/helpers.c
  Python/Python-ast.c Python/asdl.c Python/pyarena.c Python/pyctype.c
  Objects/unicodectype.c   # real UAX #31 XID tables (rejects e.g. "€" as an id)
)

echo "=== compile parser TUs ==="
for tu in "${PARSER_TUS[@]}"; do
  b="$(basename "${tu}" .c)"
  emcc ${CF} -c "${CPY}/${tu}" -o "${OUT}/${b}.o" 2>>"${OUT}/compile.log" \
    && echo "  ok  ${tu}" || { echo "  FAIL ${tu}"; tail -8 "${OUT}/compile.log"; exit 1; }
done

echo "=== compile shims (Strategy C: minimal POD object layer + AST→JSON + errors) ==="
for s in pod_real pod_stubs ast_dump wp_errors; do
  emcc ${CF} -c "${REPO}/shims/${s}.c" -o "${OUT}/${s}.o" 2>>"${OUT}/compile.log" \
    && echo "  ok  shims/${s}.c" || { echo "  FAIL shims/${s}.c"; tail -12 "${OUT}/compile.log"; exit 1; }
done

echo "=== link build/fasthon_mod.js (CommonJS) ==="
OBJS="$(ls "${OUT}"/*.o)"
EXP='-s EXPORTED_FUNCTIONS=["_fasthon_dump","_fasthon_dump_module","_fasthon_parse_only","_malloc","_free"] -s EXPORTED_RUNTIME_METHODS=["ccall","cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8"]'
emcc -O2 ${OBJS} \
     -Wl,--wrap=_PyPegen_raise_error_known_location \
     -Wl,--wrap=_PyTokenizer_syntaxerror \
     -Wl,--wrap=_PyTokenizer_syntaxerror_known_range \
     -s ALLOW_MEMORY_GROWTH=1 -s STACK_SIZE=8MB -s MODULARIZE=1 \
     -s EXPORT_NAME=createFasthon -s INVOKE_RUN=0 ${EXP} \
     -o "${OUT}/fasthon_mod.js" 2>"${OUT}/link.log" \
  && echo "Built: build/fasthon_mod.{js,wasm}  ($(stat -c%s "${OUT}/fasthon_mod.wasm") B wasm)" \
  || { echo "LINK FAIL"; tail -20 "${OUT}/link.log"; exit 1; }
