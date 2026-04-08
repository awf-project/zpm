# Project Brief: zpm

Generated: 2026-04-08

### 1. Vision Statement
ZPM transforms Large Language Models from probabilistic predictors into rigorous logical thinkers by bridging high-performance systems programming with symbolic reasoning. By embedding a Prolog inference engine directly into the Model Context Protocol (MCP) workflow, ZPM enables AI agents to maintain absolute factual integrity and navigate complex knowledge dependencies with near-zero latency. This project enables a future where AI reasoning is not just "likely" correct, but formally verifiable and computationally efficient.

### 2. Business Objectives
- **Objective:** Eliminate "fuzzy" reasoning errors in mission-critical AI applications | **Success Metric:** Achieve 100% deterministic accuracy for factual retrieval tasks compared to vector-only RAG systems.
- **Objective:** Minimize operational costs for AI infrastructure | **Success Metric:** Reduce RAM and CPU overhead by 80% compared to traditional Python-based knowledge graph implementations.
- **Objective:** Accelerate developer time-to-market for complex AI agents | **Success Metric:** Enable developers to implement complex business logic rules in <50 lines of Prolog/Zig code.
- **Objective:** Establish ZPM as the performance standard for MCP servers | **Success Metric:** Reach 5,000+ active developer installations within the first year of release.

### 3. User Personas

**Persona 1: Alex, Senior AI Architect**
- **Role:** Leads the AI platform team at a FinTech enterprise.
- **Demographics:** 35-45 years old; highly tech-savvy; expert in RAG and LLM orchestration.
- **Goals:** Build autonomous agents that can navigate complex regulatory compliance rules without hallucinating.
- **Pain Points:** Vector databases return "semantically similar" results that are factually wrong for legal/financial logic.
- **How ZPM helps:** Provides a "Source of Truth" where compliance rules are enforced as hard logical predicates that the LLM cannot ignore.

**Persona 2: Sarah, Backend Systems Engineer**
- **Role:** Individual contributor at a high-growth startup.
- **Demographics:** 24-30 years old; obsessed with performance and "low-level" languages like Zig and Rust.
- **Goals:** Deploy an AI-powered code analysis tool that runs locally on developer machines.
- **Pain Points:** Existing AI frameworks are too heavy, requiring gigabytes of RAM and slow Python runtimes for simple logic.
- **How ZPM helps:** Delivers a single, tiny Zig binary that provides lightning-fast logical inference with minimal resource footprint.

### 4. Technical Constraints
- **Performance Requirements:** Sub-5ms latency for the Zig-to-Prolog bridge; support for 1,000+ concurrent logical queries per second on modest hardware.
- **Security Requirements:** Execution must be local-first; the Prolog engine must be sandboxed to prevent resource exhaustion (e.g., infinite recursion limits).
- **Integration Requirements:** Strict adherence to the Model Context Protocol (MCP) specification; use of Protobuf for internal message serialization where performance is critical.
- **Infrastructure Preferences:** Statically linked binary with zero external dependencies; must run on Linux, macOS (Intel/Silicon), and Windows.

### 5. MVP Scope
- **User Story 1:** As a developer, I can assert facts into ZPM via MCP so that the LLM maintains a persistent, verifiable memory of a conversation.
- **User Story 2:** As a developer, I can define recursive Prolog rules so that the AI can automatically discover hidden relationships in complex data sets.
- **User Story 3:** As an AI agent, I can query the Prolog engine via MCP to get deterministic "Yes/No" or "Value" answers for logical checks.
- **User Story 4:** As a developer, I can load pre-defined `.pl` (Prolog) files into the server at startup to bootstrap the agent's "World Model."
- **User Story 5:** As a developer, I can use the "Explain" tool to see the logical proof-path taken by the engine for any given inference.
- **User Story 6:** As a system admin, I can monitor memory and query execution time via a lightweight CLI dashboard.
- **Out-of-Scope v1:** Multi-user authentication/RBAC, cloud-hosted distributed logic clusters, GUI-based rule builder, non-MCP transport layers (e.g., raw WebSockets).

### 6. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **Prolog Learning Curve** | High | High | Provide a library of "Common Logic Templates" and a high-level Zig DSL to abstract raw Prolog syntax. |
| **Infinite Recursion/Loops** | Medium | Medium | Implement strict query execution timeouts and a maximum recursion depth in the Zig orchestration layer. |
| **MCP Spec Volatility** | Medium | Medium | Maintain a modular transport layer that can be updated independently of the core inference engine. |
| **Memory Management in Zig/C** | Low | High | Utilize Zig's explicit memory allocation and safety features; perform rigorous leak testing with Valgrind/ASan. |
| **Performance Bottlenecks in C-Interop** | Low | Medium | Use direct C-ABI binding for the Prolog engine to minimize marshaling overhead. |

### 7. Success Metrics
- **Metric:** Query Response Latency | **Target:** <10ms P99 for queries involving up to 1,000 predicates | **Measurement:** Integrated telemetry and benchmarking suite.
- **Metric:** Logic Integrity | **Target:** 0% Logical Hallucination Rate | **Measurement:** Automated test suite comparing LLM output vs. Prolog ground truth.
- **Metric:** Binary Footprint | **Target:** <10MB total size | **Measurement:** Post-build artifact analysis.
- **Metric:** Developer Onboarding | **Target:** <15 minutes to first "Hello World" | **Measurement:** User testing and documentation feedback.
