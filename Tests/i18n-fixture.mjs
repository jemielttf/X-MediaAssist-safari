import { readFile } from "node:fs/promises";

export const messages = Object.fromEntries(await Promise.all(["en", "ja"].map(async language => [language,
  JSON.parse(await readFile(new URL(`../Extension/_locales/${language}/messages.json`, import.meta.url), "utf8"))
])));

// Model the WebExtension API using the actual catalogs; production uses Safari's API.
export function createI18n(language) {
  const catalog = messages[language] ?? messages.en;
  return { getMessage(key, substitutions = []) {
    return (catalog[key] ?? messages.en[key])?.message.replace(/\$(\d+)/g, (_, index) => String(substitutions[Number(index) - 1] ?? "")) ?? "";
  } };
}
