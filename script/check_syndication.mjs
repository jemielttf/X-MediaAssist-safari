#!/usr/bin/env node
// Canary for the public Syndication endpoint: fetches known public posts with the
// extension's own parser and checks that each still yields a reachable MP4.
// Metadata and a HEAD request only; no media is downloaded. Exits 1 on any failure.
//
//   node script/check_syndication.mjs
import "../Extension/i18n.js";
import "../Extension/core.js";

// Public posts also used in Docs/verification.md.
const POSTS = [
  { postId: "719944021058060289", mediaType: "video" },        // @CaptainAmerica
  { postId: "700090209761779713", mediaType: "animated_gif" }  // @TwitterJP
];
const RETRY_DELAY = 30_000;

// Without a locale, core.js error texts fall back to their message keys.
globalThis.browser = { i18n: { getMessage: () => "" } };
const core = globalThis.XMediaCore;

// Same request options as downloadPost in core.js.
async function fetchPost(postId) {
  const response = await fetch(core.syndicationURL(postId), {
    credentials: "omit", redirect: "error", referrerPolicy: "no-referrer", cache: "no-store",
    signal: AbortSignal.timeout(20_000)
  });
  if (!response.ok) throw new Error(`syndication HTTP ${response.status}`);
  return response.json();
}

// The native side accepts these content types (MediaDownload.swift).
async function checkMP4(url) {
  const response = await fetch(url, { method: "HEAD", redirect: "follow", signal: AbortSignal.timeout(20_000) });
  const type = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() ?? "";
  if (response.status !== 200) throw new Error(`MP4 HEAD HTTP ${response.status}`);
  if (!["video/mp4", "application/octet-stream"].includes(type)) throw new Error(`MP4 content-type "${type}"`);
  if (!core.isMP4URL(response.url)) throw new Error(`MP4 redirected outside video.twimg.com`);
}

async function check({ postId, mediaType }) {
  const media = core.extractMedia(await fetchPost(postId), postId);
  const item = media.find(entry => entry.mediaType === mediaType);
  if (!item) throw new Error(`no ${mediaType} (found: ${media.map(entry => entry.mediaType).join(", ")})`);
  await checkMP4(item.url);
  return item;
}

let failed = 0;
for (const post of POSTS) {
  let lastError;
  // One retry absorbs a transient network or rate-limit failure.
  for (const attempt of [1, 2]) {
    try {
      const item = await check(post);
      console.log(`ok   ${post.postId} ${item.mediaType} ${new URL(item.url).pathname}`);
      lastError = undefined;
      break;
    } catch (error) {
      lastError = error;
      if (attempt === 1) await new Promise(resolve => setTimeout(resolve, RETRY_DELAY));
    }
  }
  if (lastError) {
    failed += 1;
    console.error(`FAIL ${post.postId} ${post.mediaType}: ${lastError.message}`);
  }
}
if (failed) {
  console.error(`${failed}/${POSTS.length} posts failed. X may have changed the Syndication response.`);
  process.exit(1);
}
