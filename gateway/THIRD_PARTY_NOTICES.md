# Image codec notices

The server image pipeline uses the following pinned packages. These codecs are not linked into the iOS app; generated JPEG files contain image data, not codec software.

- `@jsquash/jpeg` 1.6.0: JavaScript wrapper, Copyright 2020 Google Inc., modified by Jamie Sinclair; Apache-2.0. The bundled MozJPEG decoder has additional codec notices. See [wrapper license](licenses/jsquash-Apache-2.0.txt) and [codec licenses](licenses/jsquash-codec.md).
- `jpeg-encoder-wasm` 0.1.2: streaming Rust JPEG encoder by the package's contributors, based on the `jpeg-encoder` crate by Volker Ströbel. `(MIT OR Apache-2.0) AND IJG`. See [MIT](licenses/jpeg-encoder-MIT.txt), [Apache-2.0](licenses/jpeg-encoder-Apache-2.0.txt), and [IJG](licenses/jpeg-encoder-IJG.txt).

This software is based in part on the work of the Independent JPEG Group.

The license files are copied from the corresponding pinned npm distributions. Preserve these notices and license texts when distributing the gateway or a bundled codec implementation. npm package integrity is pinned in `package-lock.json`. The build must not fetch a codec from a client-provided URL.

`esbuild` 0.28.2 (MIT) and `workerd` 1.20260730.1 (Apache-2.0) are local development/test dependencies and are not imported into the gateway runtime. Their npm packages include their own notices.
