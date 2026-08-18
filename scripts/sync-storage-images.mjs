#!/usr/bin/env node

import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';

const assetDirectory = new URL('../supabase/seed-assets/grocery-images/', import.meta.url);
const bucket = 'grocery-images';
const supabaseUrl = process.env.SUPABASE_URL?.replace(/\/$/, '');
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !serviceRoleKey) {
  console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.');
  process.exit(1);
}

async function filesIn(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? filesIn(path) : [path];
  }));
  return files.flat();
}

function headers(contentType) {
  return {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    ...(contentType ? { 'content-type': contentType } : {}),
  };
}

const bucketResponse = await fetch(`${supabaseUrl}/storage/v1/bucket`, {
  method: 'POST',
  headers: headers('application/json'),
  body: JSON.stringify({
    id: bucket,
    name: bucket,
    public: true,
    file_size_limit: 2 * 1024 * 1024,
    allowed_mime_types: ['image/png', 'image/jpeg', 'image/webp'],
  }),
});

if (!bucketResponse.ok && bucketResponse.status !== 409) {
  throw new Error(`Unable to create ${bucket}: ${bucketResponse.status} ${await bucketResponse.text()}`);
}

const assets = (await filesIn(assetDirectory.pathname))
  .filter((file) => /\.(png|jpe?g|webp)$/i.test(file));

if (assets.length !== 12) {
  throw new Error(`Expected 12 product images, found ${assets.length}.`);
}

for (const asset of assets) {
  const objectPath = relative(assetDirectory.pathname, asset).split('\\').join('/');
  const mimeType = objectPath.endsWith('.png') ? 'image/png'
    : objectPath.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
  const response = await fetch(
    `${supabaseUrl}/storage/v1/object/${bucket}/${objectPath.split('/').map(encodeURIComponent).join('/')}`,
    { method: 'POST', headers: { ...headers(mimeType), 'x-upsert': 'true' }, body: await readFile(asset) },
  );
  if (!response.ok) {
    throw new Error(`Unable to upload ${objectPath}: ${response.status} ${await response.text()}`);
  }
  console.log(`Uploaded ${bucket}/${objectPath}`);
}
