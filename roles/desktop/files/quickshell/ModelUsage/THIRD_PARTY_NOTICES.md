# Third-party notices

## Omarchy

The plugin's architecture and component usage follow Omarchy Quattro. The Claude and Codex SVG assets are redistributed from `basecamp/omarchy` at commit `2c247e390e357ae0fee3f8565b0c816adb705e6a`. Omarchy is distributed under the MIT license:

> Copyright (c) David Heinemeier Hansson
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## DigitalPals/fedora-config

The existing Fedora/Quickshell Model Usage module at commit `6aa074432f36548381ead91ed39d57c34529e327` was the functional and segmented-meter design reference. That checkout did not contain a repository-level license. No source file, theme implementation, or asset from that repository is redistributed here; the backend and Omarchy-native QML were independently implemented against current provider and Omarchy interfaces.

CLIProxyAPI source selection and account-pool behavior were also reviewed at Fedora commit `431def720d4b905c1563d600be33ca50eed621bb`. The management protocol was checked against [`router-for-me/CLIProxyAPI`](https://github.com/router-for-me/CLIProxyAPI) at commit `5b2785617d1e7de84a9f4dee599d275a4ccd8999`. This integration is independently implemented; no source or assets from either reference are redistributed.

## T3 Code

The estimated-cost feature adapts the transcript parsing, de-duplication, model pricing, and aggregation approach from [`pingdotgg/t3code`](https://github.com/pingdotgg/t3code) at commit `afa83098064e7dca524a1e42dea3de03a883a0b6`. The React interface and Effect/TypeScript service were not redistributed; the implementation here is a native QML/Python port with a separate contract, privacy-hardened cache identifiers, Kimi token coverage, and explicit unavailable-price states.

The model lookup, custom-rate precedence, forced-refresh behavior, and guarded incremental scanning were updated with reference to commit [`ca6416ec2d1d194738bc78a81df4b82a75cb72e2`](https://github.com/pingdotgg/t3code/tree/ca6416ec2d1d194738bc78a81df4b82a75cb72e2). The Python scanner retains this project’s bounded reads, explicit partial coverage, and SHA-256 identifiers and guards.

T3 Code is distributed under the MIT license:

> MIT License
>
> Copyright (c) 2026 T3 Tools Inc.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## LiteLLM model prices

Estimated model costs use the public [`model_prices_and_context_window.json`](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) maintained by BerriAI/LiteLLM. The table is fetched on demand, projected to the required rate fields, and cached locally; no snapshot is packaged with this plugin. Content outside LiteLLM's `enterprise/` directory is MIT licensed, Copyright (c) 2023 Berri AI. See the [LiteLLM license](https://github.com/BerriAI/litellm/blob/main/LICENSE).

## Kimi Code

Current Kimi credential locations, endpoint shapes, fixed-point wallet units, and profile fields were checked against `MoonshotAI/kimi-cli` at commit `d723cc47ee43e5ca3c3c4ec2473f205d44acede2`. The `wire.jsonl` location, recursive subagent event envelope, and `StatusUpdate.token_usage` fields used by the Costs tab were checked again at commit `cbc15c076d17f70fec9f89c90c0502e68657f505`. Kimi CLI is distributed under the MIT license (Copyright (c) 2026 Moonshot AI). No Kimi CLI source or artwork is redistributed. `assets/kimi.svg` is an original, minimal tool glyph created for this plugin.

## Provider marks

Claude, Anthropic, OpenAI, Codex, Kimi, and Moonshot AI names and marks are the property of their respective owners. Their inclusion identifies compatible services and does not imply affiliation or endorsement.

## OmaProxy

The account browsing, email privacy, and Antigravity quota-summary protocol were informed by [`soojy/omaproxy`](https://github.com/soojy/omaproxy) at commit `f61b92f02b3e75f75dc6c6cbd8c1556fdc3c5901`. The interface uses this plugin’s native Omarchy components and fixed-block meters. OmaProxy’s license follows:

> MIT License
>
> Copyright (c) 2026 OmaProxy contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
