# Project Context & Workspace Directory

We are building a production-grade DataOps monorepo.

> **⚠️ Portfolio Project Context:** This is a **personal portfolio project** to demonstrate production-grade data engineering knowledge. All architecture, infrastructure, CI/CD, and monitoring must be designed to **production-grade standards**. However, **only the `dev` environment will actively run** — at small scale and minimal cost. The `prod` environment will have fully provisioned infrastructure (Cloud Run, service accounts, datasets, Dataform, etc.) but **will never be actively used**. The CI/CD pipeline must correctly promote to production, but production workloads will not execute. Cost optimization is critical: stay within GCP Free Tier limits wherever possible.

* **Cloud Provider:** Google Cloud Platform (GCP)
* **GCP Project ID:** `emilio-flores-portfolio` (with `-dev` and `-prod` environment variations)
* **Pipeline Architecture:** API → GCS → EventArc → Cloud Run → Dataform → Spanner.
* **Infrastructure:** 100% deployed via Terraform.
* **CI/CD:** GitHub Actions pipelines for infrastructure and application code.
* **Monitoring Stack:** Datadog Pro Account (10 servers, free for 2 years). Metrics, logs, and APM traces must be forwarded to Datadog.
* **Repository:** https://github.com/EmilioFC99/gcp-end-to-end-data-pipeline

## Target Repository Layout:
```text
gcp-end-to-end-data-pipeline/
├── .github/
│   └── workflows/                     # CI/CD pipelines
├── docs/                              # Project documentation
│   ├── designs/                       # Phase 1: Design MD files
│   └── plans/                         # Phase 2: Implementation MD files
├── infrastructure/                    # Terraform IaC
│   ├── modules/
│   │   └── <module>/                  # Modular GCP infrastructure components
│   ├── environments/
│   │   ├── dev/                       # Dev TF definitions
│   │   └── prod/                      # Prod TF definitions
│   └── tests/                         # Terratest definitions
├── src/
│   ├── extractor/                     # Python API → GCS extraction service
│   │   ├── main.py
│   │   ├── Dockerfile
│   │   └── tests/
│   ├── cloud-run-dataform-trigger/    # EventArc-triggered worker
│   │   ├── main.py
│   │   ├── Dockerfile
│   │   └── tests/
│   └── dataform/                      # SQLX analytical transformations
│       ├── dataform.json
│       ├── definitions/
│       │   ├── sources.sqlx
│       │   ├── transformations/
│       │   └── monitoring/
│       └── tests/
├── monitoring/                        # Grafana / Cloud Monitoring
└── Makefile                           # Local development orchestrator
```

## Project Standards & Conventions

### Python
| Standard | Value |
|---|---|
| **Version** | 3.12 |
| **Package Manager** | `pip` with `pyproject.toml` (PEP 621) |
| **Linting** | `ruff` (`ruff check .` + `ruff format --check .`) |
| **Type Checking** | `mypy` (strict mode) |
| **Testing** | `pytest` with `pytest-cov` |
| **HTTP Mocking** | `responses` library |
| **Logging** | `structlog` (JSON output → Datadog) |
| **Tracing** | `ddtrace` (Datadog APM) |
| **Docker Base Image** | `python:3.12-slim` (multi-stage builds) |

### Terraform Modules
| Standard | Value |
|---|---|
| **Provider** | `hashicorp/google ~> 5.0` |
| **Region** | `us-central1` |
| **Required Variables** | Every module **must** accept `environment` (string: `"dev"` or `"prod"`) and `project_id` (string) |
| **Resource Naming** | `{purpose}-{environment}` (e.g., `riot-raw-data-dev`) |
| **Module Structure** | `main.tf` (resources), `variables.tf` (inputs), `outputs.tf` (outputs) |

### CI/CD (GitHub Actions)
| Standard | Value |
|---|---|
| **Branch Strategy** | Feature branches → PR to `continuous` → merge to `continuous` triggers deploy |
| **Auth Pattern** | Workload Identity Federation (WIF) via GitHub Environments (`development` / `production`) |
| **Deploy Flow** | Auto-apply to `dev` → manual approval gate → apply to `prod` |
| **Infra Trigger** | Path filter: `infrastructure/**` |
| **App Trigger** | Path filter: `src/**` |

### Docker / Container Registry
| Standard | Value |
|---|---|
| **Registry** | Google Artifact Registry (`us-central1-docker.pkg.dev/emilio-flores-portfolio/dataops-registry`) |
| **Image Tagging (Dev)** | Short Git SHA (e.g., `sha-1234567`) + `latest` alias — built and deployed automatically |
| **Image Tagging (Prod)** | Immutable promotion — the exact same Git SHA tested in Dev is deployed to Prod along with the `latest` tag. |
| **Build Strategy** | Multi-stage builds (builder + runtime) |

## Current Repository State

The workspace contains the initial scaffolding, infrastructure bootstrapping code, CI/CD pipelines, and implementation plans, but the application services (`src/`), documentation directory (`docs/`), and local orchestration (`Makefile`) are not yet created:

### Active Infrastructure Resources

| Resource | Location | Status | Notes |
|---|---|---|---|
| TF state bucket (dev) | `gs://tf-state-emilio-flores-dev` | ✅ Deployed | Created by bootstrap script |
| TF state bucket (prod) | `gs://tf-state-emilio-flores-prod` | ✅ Deployed | Created by bootstrap script |
| WIF pool + provider | Hub project (`emilio-flores-portfolio`) | ✅ Deployed | Created by bootstrap script |
| TF dev SA | `tf-dev-sa@emilio-flores-portfolio.iam.gserviceaccount.com` | ✅ Deployed | `roles/editor` on dev project |
| TF prod SA | `tf-prod-sa@emilio-flores-portfolio.iam.gserviceaccount.com` | ✅ Deployed | `roles/editor` on prod project |
| `cloud-storage` module | `infrastructure/modules/cloud-storage/` | ⚠️ Scaffolded | `variables.tf` defined, `main.tf` is blank |

### 1. Scaffolding & Configuration
- **GitHub Actions Workflows:** 
  - [.github/workflows/infra-ci.yml](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/.github/workflows/infra-ci.yml): Triggers on pull requests affecting `infrastructure/**` to perform `terraform plan` for both development and production.
  - [.github/workflows/infra-deploy.yml](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/.github/workflows/infra-deploy.yml): Triggers on pushes to the `continuous` branch. Automatically applies Terraform changes to `dev`, and prompts a manual approval gate before applying to `prod`.
- **VS Code Settings:** Pre-configured [.vscode](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/.vscode) directory.

### 2. Infrastructure Setup (`/infrastructure`)
- **Bootstrap Script:** [infrastructure/scripts/setup.sh](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/infrastructure/scripts/setup.sh) configures the intial Terraform state buckets, environment service accounts, and Workload Identity Federation (WIF) pools.
- **Environments:** 
  - [infrastructure/environments/dev/](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/infrastructure/environments/dev) and [infrastructure/environments/prod/](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/infrastructure/environments/prod) are initialized with backend configurations pointing to remote GCS state buckets (`tf-state-emilio-flores-dev` / `tf-state-emilio-flores-prod`).
- **Modules:**
  - [infrastructure/modules/cloud-storage/](file:///Users/emilio.flores/repos/gcp-end-to-end-data-pipeline/infrastructure/modules/cloud-storage) is defined with `variables.tf`, but `main.tf` is currently blank.
