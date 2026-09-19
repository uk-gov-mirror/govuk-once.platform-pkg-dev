# platform-pkg-dev

Core development tooling for the Connect platform. Every other Connect package depends
on this one.

It does two jobs:

1. **Scaffolds** new packages with `dev init`.
2. **Owns the toolchain** — every version lives in `versions.json`, and
   `dev sync` keeps each package matching it.

## Getting started

`dev init` cannot be the first step: it lives in `platform-pkg-dev`, which is
not installed until a `package.json` exists that depends on it. `start.sh`
closes that loop:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/govuk-once/platform-pkg-dev/main/start.sh)" -- --dir connect-foo --name connect-foo --team identity --assumerole connect-development-admin
```

`--assumerole` assumes a GDS role and authorises CodeArtifact before install,
so pnpm can pull `@govuk-connect` packages from the private registry. The role
is also written into the generated `package.json` under `once.aws.roles`.

It checks Node, pins pnpm through corepack, writes a throwaway `package.json`,
installs, assumes the role and authorises CodeArtifact (when `--assumerole` is
given), runs `dev init` (which replaces that manifest with the real one), and
installs again for the dependency set `init` added.

`--dir` names a folder to create. Without it an empty directory is used as-is
and a non-empty one prompts — piping this into the wrong place cannot quietly
scatter files over an existing project. With no terminal to ask, it refuses.

The throwaway manifest carries `once.bootstrap: true`, which is the only reason
`init` is willing to replace it; any other existing `package.json` is left
alone.

In a package that already has `platform-pkg-dev` installed, run `dev init` directly:

```sh
cd connect-org
pnpm dev init
```

### Testing the bootstrap locally

`start.sh` defaults to a published `platform-pkg-dev`, which does not exist yet.
The three pins are overridable from the environment, so point `PKG_DEV` at a
local checkout and it works offline:

```sh
bash platform-pkg-dev/start.sh --local --dir connect-trial --name connect-trial --team connect-team --assumerole connect-development-admin
```

The `link:` path is resolved from the **new package directory**, not from where
you ran the command — which is why `../platform-pkg-dev` works when `--dir`
creates a sibling of the platform-pkg-dev checkout.

It asks four questions — package name, team, whether to add CDK, and whether the
package will be published — then writes:

| File                                     | Notes                                                                       |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `package.json`                           | No `scripts` block; `type: module`, `sideEffects: false`, `files: ["dist"]` |
| `.nvmrc`                                 | Node 24                                                                     |
| `.gitignore`                             | Gains CDK entries when CDK is selected                                      |
| `.pre-commit-config.yaml`                | Generated from platform-pkg-dev's master config                             |
| `pre-commit.extend.yaml.example`         | Per-package hook overrides, renamed to activate                             |
| `.oxlintrc.json`                         | Extends `platform-pkg-dev/oxlint.base.json`                                 |
| `.oxfmtrc.json`                          | Generated formatter config                                                  |
| `.githooks/`                             | pre-commit and pre-push, delegating to pre-commit                           |
| `.vscode/`                               | Recommends the oxc extension, fixes on save                                 |
| `tsconfig.json`                          | Extends `platform-pkg-dev/tsconfig.base.json`                               |
| `README.md`, `src/index.ts`              | Starting point                                                              |
| `tsconfig.esm.json`, `tsconfig.cjs.json` | Published packages only                                                     |
| `cdk.json`, `src/infra/`                 | CDK packages only                                                           |

Nothing is written until the environment check passes. `init` verifies `git`
and `pnpm` are present, and that `pre-commit` is installed at **exactly** the
version pinned in `versions.json`. A failed check leaves the target directory
untouched rather than half-scaffolded. semgrep, checkov and detect-secrets are
not checked - pre-commit installs those itself.

## How a package tracks platform-pkg-dev

Three mechanisms, in order of preference:

|               | Files                                                            | How a change reaches a package                                                                                                                             |
| ------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Extends**   | `tsconfig.json`, `tsconfig.esm/cjs.json`, `.oxlintrc.json`       | Immediately. They point back at `platform-pkg-dev/tsconfig.base.json` and `platform-pkg-dev/oxlint.base.json`, so nothing is copied and nothing can drift. |
| **Delegates** | `.githooks/pre-commit`, `.githooks/pre-push`                     | Immediately. Three lines that resolve the package root from their own path and hand over to `platform-pkg-dev/hooks/dev-hook`, where the logic lives.      |
| **Generated** | `.pre-commit-config.yaml`, `.oxfmtrc.json`, `.nvmrc`, `.vscode/` | On `dev sync`. These formats have no `extends` mechanism, so platform-pkg-dev regenerates them outright and `sync --check` fails if they have been edited. |

Seed files — `README.md`, `src/`, `.gitignore` — are written once and then belong
to the package. `--force` will not overwrite them.

Package-specific escape hatches, none of them managed:

- `pre-commit.extend.yaml` — merges hooks into the generated pre-commit config.
- `.githooks/pre-commit.extend.sh`, `.githooks/pre-push.extend.sh` — shell run
  after the shared chain passes; a non-zero exit blocks the commit or push.
  They sit beside the hooks that run them; `pre-commit.extend.yaml` stays in the
  package root beside the config it merges into.
- `.oxlintrc.json` — extends the shared rules, so add overrides freely.

Each ships as a `.example`, and `*.example` is gitignored.

Existing files are never overwritten unless you pass `--force`; each one is
reported as left alone.

See `dev init --help` for the non-interactive flags.

### What `init` does after writing the files

Two steps that used to be left to the reader, because leaving them out produced
a package that failed its own checks before anyone had touched it:

- **Formats what it wrote.** oxfmt has its own canonical key order for
  `package.json`, which the manifest builder does not try to reproduce. Without
  this a fresh package failed `dev format --check` immediately, and the first
  commit's format hook rewrote a file nobody had edited.
- **Runs `pnpm install`.** Until it has, the package has no `dev` binary — so
  every command in the next-steps notes, `dev hooks install` included, would
  have failed. `--no-install` skips it.

### `dev cdk:init`

Separate from `dev init` because it needs the CDK CLI, which is not installed
until after the first `pnpm install`.

```sh
pnpm dev cdk:init          # --dir <name> to use something other than cdk/
```

It runs `cdk init --generate-only`, removes what platform-pkg-dev already owns
(the generated `package.json`, `tsconfig.json`, Jest config, `test/`,
`.gitignore`, `README.md`), then writes `bin/app.ts`, `lib/main.stack.ts` and
`cdk/tsconfig.json` from platform-pkg-dev's templates and repoints `cdk.json` at
`node bin/app.ts`.

The generated `cdk.json` is kept, and that is the whole reason for shelling out
to `cdk init` at all: it carries around ninety context feature flags that must
match the CDK version, and hand-maintaining that list in a template would rot on
every upgrade.

Inside that directory, relative imports carry a **`.ts`** extension — it runs
through Node's type stripping with `noEmit`, so the specifier names the real
file. Everywhere else, imports end `.js`, naming the file that will be emitted.

### `dev synth` and `dev scan`

Synthesising against a real account needs credentials for it. `dev synth`
assumes a GDS role and runs `cdk synth` with them; `dev scan` does that and
then runs checkov over the resulting templates.

```sh
pnpm dev synth              # every stack
pnpm dev synth UdpMainStack # one
pnpm dev scan               # synth, then checkov
pnpm dev scan CKV_AWS_158   # one check, while fixing it
```

Roles are declared per package, so no script hardcodes an account:

```jsonc
"once": {
  "team": "platform",
  "aws": { "region": "eu-west-2", "roles": { "dev": "connect-udp-development-admin" } }
}
```

One configured role is used without ceremony. With more than one, the choice
has to be explicit — `--env`, or `ENV` — because assuming the wrong account is
not a mistake worth making quietly.

**Credentials are parsed, never `eval`ed.** The shell scripts this replaces ran
`eval "$CREDS"`, which hands whatever the command printed to the shell: a single
backtick in an error message is enough to execute something. platform-pkg-dev parses the
output instead, and passes through only an allowlist of `AWS_*` variables — so
nothing in it can alter `PATH`, `NODE_OPTIONS` or `AWS_PROFILE` and change what
the child process _is_ rather than who it runs as. Credentials never touch disk
and never appear in a process argument, so they cannot be read out of `ps`.

The role is verified with `sts get-caller-identity` before anything
long-running starts: a role can be assumed and still be unusable off-VPN, and
finding that out from a failed synth is a much worse error message.

`cdk.out` is removed first. A template left from a previous run is still
scanned, so a stack you have since deleted would keep failing.

Scanning synthesised templates rather than source is the point: checkov reads
CloudFormation, and a construct's real properties — including everything CDK
fills in for you — only exist after synth. The pre-push hook also runs checkov,
but over files; this is the one to trust before a deployment.

## Toolchain commands

```sh
pnpm dev build                # tsc, dual ESM/CJS when both tsconfigs are present
pnpm dev test                 # vitest, once
pnpm dev test:watch           # vitest, re-running affected tests on save
pnpm dev lint                 # oxlint, type-aware, with the shared Connect config
pnpm dev format               # oxfmt (--check to verify without writing)
pnpm dev typecheck            # tsc --noEmit
pnpm dev sync                 # re-pin managed deps, then pnpm install
pnpm dev cdk:init             # scaffold the CDK app - see below
pnpm dev hooks install        # wire .githooks and pre-build the hook environments
pnpm dev doctor               # verify the pinned tool versions on this machine
pnpm dev write-markers        # dist/{esm,cjs}/package.json type markers
pnpm dev assumeRole <role>    # assume a GDS role and print credentials
pnpm dev codeArtifactAuthorise --role <role>  # assume role + authorise CodeArtifact
```

Under pnpm, only _direct_ dependencies get their binaries linked into
`node_modules/.bin`. A package that depends on `platform-pkg-dev` therefore has no `tsc`
or `vitest` on its path — these wrappers resolve the binaries from
`platform-pkg-dev`'s own install and run them for you.

They also run from the **nearest package root**, not the caller's working
directory, so calling them from deep inside `src/` behaves identically to
calling them from the top. Override with `--cwd <path>` or `DEV_CWD`.

### Why `build` writes `package.json` markers

Node decides whether a `.js` file is ESM or CommonJS by looking at the nearest
`package.json` `type` field. A published package has `"type": "module"` at its
root, which means _everything_ under `dist/` is treated as ESM — including the
CommonJS output in `dist/cjs`, where `require()` then fails.

Writing a two-line `dist/cjs/package.json` containing `{"type":"commonjs"}`
(and `dist/esm/package.json` with `{"type":"module"}`) scopes the format to that
subtree. Bundlers like tsup and rollup avoid the problem by emitting `.cjs` and
`.mjs` extensions instead; with plain `tsc`, the markers are the equivalent.

`dev build` writes them automatically after a successful dual build, and
skips them if either compile fails.

### Upgrading platform-pkg-dev

`dev sync` checks whether a newer platform-pkg-dev exists before doing anything
else, because every pin it enforces comes from platform-pkg-dev — syncing
against an old copy just reapplies old versions.

It reads a plain-text file containing nothing but the version, served alongside
`start.sh`:

```
versions.json  ->  "versionUrl": "https://raw.githubusercontent.com/govuk-once/platform-pkg-dev/main/VERSION"
```

Deliberately not the npm registry: platform-pkg-dev is served from wherever `start.sh`
is, which need not be npm. Point `DEV_VERSION_URL` elsewhere to override,
including at a `file:` URL for local testing. Set `versionUrl` to `null` to turn
the check off.

When it finds a newer version it rewrites the `platform-pkg-dev` spec, installs, and
**re-runs sync under the new version** — the process already in memory would
otherwise reapply the pins it shipped with. Guards, all tested:

- A `link:`, `file:` or `workspace:` spec is never rewritten — that is someone
  developing platform-pkg-dev itself.
- A response that is not a version string is ignored, so a proxy returning an
  HTML error page cannot be mistaken for a release.
- If the install fails, `package.json` is **rolled back**. A package pinned to a
  version that could not be installed is worse off than one that has not
  upgraded yet.
- `--no-install` skips the check rather than doing half of it; `--no-upgrade`
  skips it outright.
- Unreachable, missing, or still-a-placeholder URL is a silent skip, never an
  error.

## Version pins

Every version `platform-pkg-dev` hands out lives in [`versions.json`](versions.json) —
plain data, no TypeScript, readable even in an installed copy:

```json
{
  "node": 24,
  "packageManager": "pnpm@10.26.0",
  "versions": {
    "typescript": "7.0.2",
    "aws-cdk-lib": "2.266.0",
    "constructs": "10.8.1"
  }
}
```

[`src/versions.ts`](src/versions.ts) loads it and fails loudly on a missing
entry rather than emitting `undefined` into a generated `package.json`.

### Why some deps are declared per package

The toolchain reaches consumers through the `dev` wrappers, which resolve
binaries from platform-pkg-dev's own install. That does **not** work for `import`:
pnpm's strict `node_modules` means a bare `import 'aws-cdk-lib'` cannot resolve
a dependency the package has not declared. Hoisting it works only when
platform-pkg-dev is installed from a registry, not via `link:`, so it would
behave differently on
your laptop and in CI. Duplicate copies of `aws-cdk-lib`/`constructs` also break
CDK's `instanceof` and jsii type checks.

So anything a package _imports_ is declared in its own `package.json`, pinned
exactly — and [`dev sync`](#dev-sync) keeps those pins equal to
`versions.json`. One place to change the version; strict resolution and a single
copy of CDK preserved.

## `dev sync`

```sh
dev sync           # re-pin managed deps, then pnpm install
dev sync --check   # report drift, exit 1, change nothing
dev sync --no-install
```

Enforces `@types/node` for every package, plus `aws-cdk-lib`, `constructs` and
`aws-cdk` for packages that already use CDK, plus `packageManager` and
`engines.node`. CDK pins are enforced only once a package uses CDK, never
forced on.

Specs are compared as literal strings, so `^2.266.0` is drift from `2.266.0`: a
range is not a pin. Existing keys keep their position, so a sync produces the
smallest possible diff, and unmanaged dependencies are left alone. `init` writes
the initial `package.json` from the same pin list, so a fresh package starts in
sync by construction.

## Git hooks

Hooks are run by [pre-commit](https://pre-commit.com), which installs each hook
repo into its own isolated environment at a pinned revision. That is the whole
reason for using it: **semgrep, checkov and detect-secrets are never installed
globally and cannot drift** — `pre-commit` is the single tool a developer
installs by hand.

The hook scripts themselves are committed in `.githooks/` rather than generated
into `.git/hooks`, so they stay reviewable. They hand straight off to
pre-commit's own entry point:

```sh
# after checking node_modules, pre-commit, and `dev sync --check`
exec pre-commit hook-impl --config=.pre-commit-config.yaml --hook-type=pre-commit -- "$@"
```

`dev sync --check` runs **before** pre-commit, never as a hook inside the
chain. pre-commit parses `.pre-commit-config.yaml` once at start-up, so a hook
in the chain would be validating a config that had already been used to decide
what to run. Both the git hook and `dev pre-commit` check first and stop:

```
platform-pkg-dev: this package has drifted from the platform-pkg-dev pins.
  ~ .pre-commit-config.yaml
      - args: [ --maxkb=512 ]
      + args: [ --maxkb=256 ]
platform-pkg-dev: run 'dev sync', then commit again.
```

Wire them up once per clone — `core.hooksPath` is local git config, and the hook
environments live in `~/.cache/pre-commit`:

```sh
dev hooks install     # sets core.hooksPath, then pre-builds every hook env
dev hooks status
dev hooks uninstall
```

`install` pre-builds the environments deliberately: pre-commit would otherwise
do it lazily on the first commit, which is a surprising multi-minute pause at
exactly the wrong moment.

### What runs, and when

**On commit** (18 hooks) — file hygiene and the cheap safety nets first, so
later hooks see auto-corrected files:

|           |                                                                                                                                              |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| hygiene   | `trailing-whitespace`, `end-of-file-fixer`, `mixed-line-ending`                                                                              |
| validity  | `check-yaml`, `check-json`, `check-toml`, `check-merge-conflict`, `check-case-conflict`, `check-symlinks`, `check-executables-have-shebangs` |
| safety    | `check-added-large-files`, `detect-private-key`, `no-commit-to-branch` (main/master)                                                         |
| secrets   | `detect-secrets`, `semgrep` (`p/typescript`, `p/secrets`)                                                                                    |
| toolchain | `dev lint`, `dev typecheck`                                                                                                                  |

**On push** (2 hooks) — the slow half, kept off the commit path: `checkov` and
`dev test`.

Both stages are preceded by `dev sync --check`, which is a prerequisite rather
than a hook — see below.

Note that `trailing-whitespace`, `end-of-file-fixer`,
`check-executables-have-shebangs` and `check-added-large-files` declare
`stages: [pre-commit, pre-push, manual]` upstream, and a hook's own `stages`
beats `default_stages`. They are overridden to `[pre-commit]` in the master
config — an auto-fixer running on push would rewrite files mid-push, fail it,
and leave a dirty tree.

### The config is generated

`.pre-commit-config.yaml` is rendered by `dev sync` from platform-pkg-dev's
[master config](templates/pre-commit/master.yaml) and carries a
do-not-edit header. pre-commit has no `extends` mechanism — an `extends:` key is
silently ignored with only a warning — so generating the file is how a master
config is shared at all.

Package-specific changes go in **`pre-commit.extend.yaml`**, as an overlay keyed
by hook id:

```yaml
detect-secrets:
  exclude:
    - ^src/testdata/.*$
    - ^docs/fixtures/.*$

semgrep:
  args:
    - --config=p/owasp-top-ten
```

`exclude` and `files` take a **list** here, even though pre-commit wants a single
regex — the entries are joined into one alternation and merged with whatever the
master already sets, so a package adds exclusions rather than replacing them.
`args`, `additional_dependencies` and `types_or` append; anything else replaces.
A `repos:` key adds entirely new hook repos.

Naming a hook that does not exist is an error listing the valid ids, so a typo
fails loudly instead of silently doing nothing:

```
x pre-commit.extend.yaml: no hook named "detect-secrts" in the platform-pkg-dev config.
  Available: trailing-whitespace, end-of-file-fixer, ... dev-test
```

The merge happens on the parsed YAML document, not by splicing text, so the
master's comments and structure survive intact.

Two exclusions in the master are worth knowing about, both found by running this
for real:

- `detect-secrets` skips lockfiles. `pnpm-lock.yaml` is full of base64 integrity
  hashes and trips the high-entropy detector on every commit that touches it.
- `detect-secrets` also skips two **lines**, via `--exclude-lines`, rather than
  the files holding them — so everything else in those files is still scanned:
  the `"detect-secrets"` hook revision in `versions.json`, where the keyword
  detector matches its own name; and `TOP_SECRET`, a UK government
  classification label, but only where the value repeats the name, which a real
  credential never does.
- `check-json` skips `.oxlintrc.json`, `.oxfmtrc.json`, `.vscode/*.json` and
  `tsconfig*.json`. Those are JSONC — oxlint, oxfmt, VS Code and tsc all accept
  comments; `check-json` does not.

Both are written as single-line regexes rather than `(?x)` verbose blocks: in
Python's `re` a leading `(?x)` is a _global_ flag, so merging a package's
patterns after one would silently put them in verbose mode too. (If an extend
pattern does carry a global flag, it is hoisted to the front of the merged
pattern rather than buried in a group, which Python rejects.)

## External tools

`pre-commit` is the only executable a developer installs by hand. It is pinned
in `versions.json` and verified by exact version:

```sh
$ dev doctor
+ pre-commit 4.5.1
+ Environment checks passed
```

Everything else the hooks use — semgrep, checkov, detect-secrets, the
pre-commit-hooks suite — is installed by pre-commit into `~/.cache/pre-commit`
at the revision pinned in `hookRevs`. For a pre-commit hook the rev _is_ the
version, so system installs are irrelevant: a machine with `detect-secrets`
already on `PATH` still runs the pinned copy from the managed environment.

## Linting

oxlint, not ESLint. `typescript-eslint` refuses to load against TypeScript 7 —
it throws on import, and even its canary still declares
`peer typescript: ">=4.8.4 <6.1.0"`. oxlint parses TypeScript with its own Rust
parser and never links against the `typescript` package, so the problem does
not exist for it.

It is also _more_ capable here, not less. `oxlint-tsgolint` — built on tsgo, the
TypeScript 7 native compiler, with a version that tracks the pinned TypeScript —
provides type-aware rules:

```
$ dev lint
src/probe.ts:6:3: error typescript(no-floating-promises): Promises must be awaited
```

`dev lint` turns on `--type-aware` automatically whenever the package has a
`tsconfig.json`, and keeps that flag even when you pass others, so
`dev lint --fix` still lints the whole package with type information.

Rules live in [`oxlint.base.json`](oxlint.base.json), next to
`tsconfig.base.json`. A package's `.oxlintrc.json` extends it out of
`node_modules`, so rules stay centrally owned:

```json
{ "extends": ["./node_modules/platform-pkg-dev/oxlint.base.json"], "rules": {} }
```

Note `oxlint-tsgolint` is a managed pin in every package's `package.json`.
oxlint resolves its type-aware engine from the _linted_ package's
`node_modules`, not from platform-pkg-dev's, so unlike `tsc` and `vitest` it cannot come
through the wrapper. `dev sync` keeps it pinned.

### Fixing, and fixing on save

```sh
dev lint --fix              # safe fixes, written to disk
dev lint --fix-suggestions  # also applies behaviour-changing suggestions
```

`--fix` rewrites files in place — for example turning `import { Stats }` into
`import type { Stats }`. Not every rule has an autofix: `eqeqeq` reports but
never rewrites `==`, on either flag.

Fix-on-save needs an editor extension; `dev init` scaffolds the configuration
for it. `.vscode/extensions.json` recommends `oxc.oxc-vscode`, and
`.vscode/settings.json` enables `source.fixAll.oxc` on save plus type-aware
diagnostics as you type. Both files are committed rather than gitignored, so the
whole team gets the same behaviour. Without the extension installed the settings
are simply inert — nothing breaks.
