import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../script/generate_manifest.sh", import.meta.url));
const template = fileURLToPath(new URL("../Extension/manifest.json.in", import.meta.url));

function generate(version, output) {
  return spawnSync("/bin/sh", [script], {
    env: { ...process.env, MARKETING_VERSION: version, SCRIPT_INPUT_FILE_0: template, SCRIPT_OUTPUT_FILE_0: output },
    encoding: "utf8"
  });
}

test("manifest generation follows the resolved version and preserves the template and other fields", async t => {
  const directory = await mkdtemp(join(tmpdir(), "xma-manifest-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const output = join(directory, "Extension Resources", "manifest.json");
  const source = await readFile(template, "utf8");
  const expected = JSON.parse(source);

  for (const version of ["0.3.7", "0.4.0"]) {
    const result = generate(version, output);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(await readFile(output, "utf8")), { ...expected, version });
  }
  assert.equal(await readFile(template, "utf8"), source);
});

test("invalid or missing versions fail without replacing an existing manifest", async t => {
  const directory = await mkdtemp(join(tmpdir(), "xma-manifest-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const output = join(directory, "manifest.json");
  const original = '{"version":"0.3.7"}\n';
  await writeFile(output, original);

  for (const version of ["", "0.3.7-beta", "1..2", "01.2.3", "65536.0.0", "1.2.3.4.5", "0.0.0"]) {
    const result = generate(version, output);
    assert.notEqual(result.status, 0, version);
    assert.equal(await readFile(output, "utf8"), original);
  }
});
