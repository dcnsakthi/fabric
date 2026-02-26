# Microsoft Fabric – Enterprise Implementation Checklist

This checklist provides a **practical, end‑to‑end guide** for implementing Microsoft Fabric in an enterprise or government tenant, covering **platform readiness, governance, security, architecture, operations, and adoption**.

---

## 1. Tenant & Platform Readiness

### Identity & Tenant
- [ ] Microsoft Entra ID tenant confirmed and ready
- [ ] Global / Fabric / Power BI Admin roles assigned
- [ ] Region and data residency validated
- [ ] Government / regulated tenant compliance validated (if applicable)

### Fabric Enablement
- [ ] Microsoft Fabric enabled at tenant level
- [ ] Required workloads enabled:
  - [ ] Data Engineering
  - [ ] Data Factory
  - [ ] Data Science
  - [ ] Data Warehouse
  - [ ] Databases
  - [ ] Real-Time Intelligence
  - [ ] IQ
  - [ ] Graph
  - [ ] Power BI
  - [ ] Industry Solutions
- [ ] Copilot in Fabric assessed (allowed / restricted / disabled)

---

## 2. Capacity, Licensing & Cost Controls

### Capacity Planning
- [ ] Initial capacity selected (Trial / P / F SKU)
- [ ] Capacity sizing aligned to PoC / Pilot / Pre-Prod / Production
- [ ] Capacity assigned to required workspaces

### Cost Governance
- [ ] Bursting and smoothing behavior understood
- [ ] Capacity Metrics App enabled
- [ ] Cost monitoring and alerting defined
- [ ] Showback / chargeback model agreed

---

## 3. Network & Security Architecture

### Network Access
- [ ] Public network access decision documented
- [ ] Private Endpoint / Private Link strategy defined
- [ ] Firewall rules and allowlists validated
- [ ] VPN / ExpressRoute dependencies confirmed

### Identity & Access
- [ ] Microsoft Entra authentication enforced
- [ ] Conditional Access policies validated
- [ ] External sharing policies reviewed
- [ ] Service principals / managed identities defined

---

## 4. Workspace & Environment Strategy

### Environment Separation
- [ ] Separate workspaces for Dev / Test / Prod
- [ ] Naming conventions standardized
- [ ] Workspace-to-capacity mapping defined

### Role Model
- [ ] Workspace Admins identified
- [ ] Contributor / Viewer roles defined
- [ ] Build permissions controlled
- [ ] Power BI sharing model approved

---

## 5. OneLake & Data Architecture

### OneLake Strategy
- [ ] OneLake defined as primary storage layer
- [ ] Folder structure aligned to data domains
- [ ] Domain ownership defined

### Lakehouse Pattern
- [ ] Bronze / Silver / Gold architecture agreed
- [ ] Raw / curated / consumption layers defined
- [ ] SQL endpoints usage defined

### External Data Access
- [ ] OneLake shortcuts strategy approved
- [ ] Dataverse shortcuts configured (if applicable)
- [ ] Databricks integration pattern validated (if applicable)

---

## 6. Ingestion & Orchestration

### Data Sources
- [ ] Source systems validated (SFTP, APIs, DBs, SaaS)
- [ ] Streaming vs batch ingestion decided

### Pipelines
- [ ] Data Factory pipelines designed
- [ ] Dependency management defined
- [ ] Scheduling windows agreed
- [ ] Error handling and retry strategy implemented

---

## 7. Analytics, BI & Consumption

### Semantic Models
- [ ] Import vs Direct Lake decision made
- [ ] Dataset ownership defined
- [ ] Refresh strategy agreed

### Reporting & Consumption
- [ ] Power BI workspace strategy aligned
- [ ] RLS / OLS strategy implemented
- [ ] Excel and Microsoft 365 consumption enabled

---

## 8. Governance, Catalog & Compliance

### Microsoft Purview Integration
- [ ] Fabric scanning enabled
- [ ] OneLake lineage captured
- [ ] End‑to‑end lineage validated

### Data Governance
- [ ] Data classification and sensitivity labels applied
- [ ] Data sharing and access policies approved
- [ ] Domain data owners assigned

---

## 9. DevOps, ALM & Automation

### Source Control & CI/CD
- [ ] Git integration enabled
- [ ] CI/CD pipelines implemented (Dev → Test → Prod)
- [ ] Parameterization strategy defined

### Release Management
- [ ] Promotion rules defined
- [ ] Approval gates implemented
- [ ] Rollback strategy documented

---

## 10. Monitoring, Operations & Support

### Monitoring
- [ ] Capacity utilization monitored
- [ ] Pipeline failure alerts enabled
- [ ] Semantic model refresh monitoring active

### Support Model
- [ ] L1 / L2 / L3 support model defined
- [ ] Incident SLAs agreed
- [ ] Operational runbooks documented

---

## 11. Security Validation & Go‑Live Readiness

- [ ] Access reviews completed
- [ ] Data exposure risks validated
- [ ] Security testing completed
- [ ] Compliance and risk sign‑off obtained

---

## 12. Adoption, CoE & Operating Model

### Center of Excellence
- [ ] Fabric CoE established
- [ ] Standards and guardrails published
- [ ] Reusable templates created

### Enablement
- [ ] Developer training completed
- [ ] Analyst onboarding completed
- [ ] Reference architecture published

---

## ✅ Production Go‑Live Checklist

- [ ] Production capacity assigned
- [ ] Production data loaded
- [ ] Governance and monitoring active
- [ ] Support model operational
- [ ] Business users onboarded

---

**Outcome:**  
A secure, governed, scalable Microsoft Fabric platform ready for enterprise and government workloads.

---
