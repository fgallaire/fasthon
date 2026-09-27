/* Round-trip a REAL stdlib file through Fasthon → $B.ast → Brython codegen,
 * compared to Brython's own parser+codegen. The ultimate scale test. */
const fs = require("fs");
const $B = require("../bry_boot.js");
globalThis.$B = $B; globalThis._b_ = $B.builtins;
const createFasthon = require("../build/fasthon_mod.js");
const WP = require("../fasthon.js").bind($B);
const { build } = WP;

function compile(mod,src){ const fn="<string>",fu=$B.future_features(mod,fn),st=$B._PySymtable_Build(mod,fn,fu); return $B.js_from_root({ast:mod,symtable:st,filename:fn,src:src||""}).js; }
function logic(js){ return js.replace(/([A-Za-z_])\d{4,}/g,"$1N").replace(/'<string>'/g,"'F'").replace(/'undefined'/g,"'F'").replace(/set_lineno\(frame, \d+\)/g,"set_lineno(frame, L)").split("\n").map(l=>l.trim()).filter(Boolean).join("\n"); }

const LIB = (() => {
    const p = require("path");
    return [process.env.CPYTHON_LIB,
            p.join(__dirname, "../../external/Python-3.14.6/Lib"),
            p.join(__dirname, "../../wasthon4/external/Python-3.14.6/Lib")]
        .find(d => d && fs.existsSync(d));
})();
const path = process.argv[2] || require("path").join(LIB, "re/_parser.py");
const SRC = fs.readFileSync(require("path").resolve(path), "utf8");

createFasthon().then(M => {
  const dumpMod = M.cwrap("fasthon_dump_module","string",["string"]);
  console.log(`file: ${path}  (${SRC.length} chars, ${SRC.split("\n").length} lines)`);
  const t0=process.hrtime.bigint();
  const json = dumpMod(SRC);
  const t1=process.hrtime.bigint();
  if (json.startsWith('{"error')) { console.log("Fasthon:", json); return; }
  const tree = JSON.parse(json);
  console.log(`Fasthon parsed → ${tree.body.length} top-level stmts, ${json.length} bytes JSON, ${(Number(t1-t0)/1e6).toFixed(1)}ms`);
  let mod, jsA, jsB;
  try { mod = build(tree); } catch(e){ console.log("BUILD ERROR:", e.message); return; }
  try { jsA = compile(mod, SRC); } catch(e){ console.log("CODEGEN(Fasthon) ERROR:", e.message); return; }
  try { jsB = $B.py2js(SRC, "t", "t").to_js(); } catch(e){ console.log("Brython couldn't compile it either:", e.message); return; }
  const norm = s => s.replace(/([A-Za-z_])\d{4,}/g,"$1N").replace(/'<string>'/g,"'F'").replace(/'undefined'/g,"'F'").replace(/set_lineno\(frame, \d+\)/g,"set_lineno(frame, L)");
  const ok = norm(jsA) === norm(jsB);
  console.log("codegen identical to Brython (whole-string):", ok ? "YES ✅" : "no", `(${jsA.length} vs ${jsB.length} bytes)`);
  if (!ok){ const A=logic(jsA).split("\n"),B=logic(jsB).split("\n"); let diffs=0;
    for(let i=0;i<Math.max(A.length,B.length);i++) if(A[i]!==B[i]){ if(diffs<2) console.log(`  @${i}\n   A: ${A[i]}\n   B: ${B[i]}`); diffs++; }
    console.log("  total differing lines:", diffs, "/", Math.max(A.length,B.length)); }
});
