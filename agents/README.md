# wined3d-windows Multi-Agent Build System

Three-agent Python workflow for iterative Wine DLL build + validation.

## Architecture

```
orchestrator.py        ← Lead Engineer (Claude claude-opus-4-5)
    │
    ├── agent_builder.py    ← Agent 1: Builder
    │       Runs build-docker.sh, diagnoses failures, applies safe fixes
    │
    └── agent_inspector.py  ← Agent 2: Inspector
            Compares built DLLs vs reference via pefile
            Reports import/export diffs with severity ratings
```

## Setup

```bash
cd agents        # from the repository root
pip3 install -r requirements.txt --break-system-packages
export ANTHROPIC_API_KEY=...   # your key; keep it in your shell profile, never in a file here
```

## Usage

```bash
# Full cycle: build Wine 8.0.2, then compare vs reference
python3 orchestrator.py 8.0.2

# Inspect only (skip build, use existing output/)
python3 orchestrator.py 8.0.2 --inspect-only

# Build only (no inspection)
python3 orchestrator.py 8.0.2 --build-only

# More retries
python3 orchestrator.py 8.0.2 --max-attempts 5

# Run up to 3 full cycles (build → inspect → lead review → repeat)
python3 orchestrator.py 8.0.2 --max-cycles 3
```

## Agent roles

### Agent 1 — Builder (`agent_builder.py`)
1. Runs `./build-docker.sh --force --progress=plain --versions <version>`
2. On failure, sends log tail to Claude for diagnosis
3. Claude classifies error type and suggests a targeted fix
4. Safe fixes applied automatically (flag changes, sed patches, .def tweaks)
5. Escalates to lead engineer if: core Wine logic needs changing, or fix failed

### Agent 2 — Inspector (`agent_inspector.py`)
1. Uses `pefile` to extract exports + imports from built DLLs
2. Compares against reference DLLs at `tests/emu/reference/<version>/` (override with `QEMU3DFX_REF`)
3. Flags: missing exports, extra exports, dangerous imports (ucrtbase etc.)
4. Sends diff to Claude for severity classification + root-cause analysis

### Lead Engineer (`orchestrator.py`)
1. Receives both reports
2. Synthesizes via Claude → prioritized fix list with exact code changes
3. Interactively asks: apply fixes and rebuild?
4. Saves all reports as JSON in `output/_reports/`

## Output

Reports saved to `output/_reports/`:
- `8.0.2_cycle01_builder.json`    raw builder agent output
- `8.0.2_cycle01_inspector.json`  raw inspector output
- `8.0.2_cycle01_lead.json`       lead engineer synthesis + fix list

## Fix categories

| Type              | Description                                  | Auto-applied?  |
|-------------------|----------------------------------------------|----------------|
| `DOCKERFILE_PATCH`| sed/perl patch in Dockerfile RUN layer       | Yes            |
| `MAKEFILE_FLAG`   | Compiler/linker flag in Makefile or config.mk| Yes            |
| `DEF_EXPORT`      | Missing symbol added to .def file            | Yes            |
| `COMPAT_OBJECT`   | New .c file needed in docker/                | No — escalated |
| `BUILD_SCRIPT`    | Change to build-docker.sh logic              | No — escalated |

## Paths

- Project: the repository root (parent of `agents/`); override with `WINED3D_PROJECT_DIR`
- Output:  `output/<version>/` (wined3d.dll, ddraw.dll, d3d8.dll, d3d9.dll)
- Reference: `tests/emu/reference/<version>/` (override with `QEMU3DFX_REF`)
- Reports: `output/_reports/`
