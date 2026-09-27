# Editor de Policy Synapse + Sandbox de teste

Esta feature adiciona ao Publisher um editor de código para operation policies Synapse
(Monaco + diagrama de fluxo ao vivo, com paleta de mediadores e templates prontos) e um
painel de teste que executa a policy de verdade num Gateway, através de um novo endpoint
de sandbox — sem precisar publicar a API nem gastar uma subscription real.

## Repositórios e forks

A feature está distribuída em três repositórios, todos no branch `feature/policy-editor-sandbox`:

| Repositório | Fork | Base |
|---|---|---|
| `carbon-apimgt` | `edubencz/carbon-apimgt` | tag `v9.33.176` |
| `apim-apps` | `edubencz/apim-apps` | tag `v9.3.194` |
| `product-apim` (este repositório) | `edubencz/product-apim` | `master` (commit `9e253b105`) |

- **carbon-apimgt**: runtime do sandbox no Gateway (`gateway/sandbox/`), o endpoint REST
  `POST /policy-sandbox/execute`, a config `OperationPolicySandboxConfig` +
  `GatewaySandboxClient` no Control Plane, e os endpoints `/render`, `/test`,
  `/test/environments` e `/definition` no Publisher.
- **apim-apps**: o editor (`PolicyForm/Editor/`) — Monaco, diagrama SVG, paleta, templates
  — e o painel de teste (`Editor/test/`), integrados nas telas de criar/ver policy.
- **product-apim**: config default (`default.json`) e exemplo comentado no
  `deployment.toml` para os três perfis (`all-in-one-apim`, `api-control-plane`, `gateway`).

## Build (Windows, JDK 21)

A ordem importa: `carbon-apimgt` precisa estar instalado no `.m2` local antes de
`apim-apps`, que por sua vez precisa estar publicado antes do build do produto.

1. **carbon-apimgt**
   ```
   mvn install -DskipTests -Dcheckstyle.skip=true
   ```
   (o upstream já tem milhares de violações de checkstyle; puladas de propósito.)

2. **apim-apps**
   ```
   npm config set script-shell "C:\Program Files\Git\bin\bash.exe"
   mvn install -DskipTests
   ```
   (o webpack/npm scripts deste projeto esperam um shell POSIX; no Windows isso precisa
   apontar explicitamente para o bash do Git.)

3. **product-apim** (all-in-one, exemplo — mesma lógica para `api-control-plane` e
   `gateway`)
   ```
   mvn install -DskipTests -pl modules/p2-profile/product,modules/distribution/product -am
   ```

## Como habilitar

A flag principal fica em `default.json`:

```
"apim.policy_sandbox.enable": false,
"apim.policy_sandbox.timeout": 30000,
"apim.policy_sandbox.execution_timeout": 20000,
"apim.policy_sandbox.max_concurrent_runs": 4,
"apim.policy_sandbox.max_log_lines": 500
```

Para ligar num `deployment.toml`, adicione o bloco `[apim.policy_sandbox]` **depois** da
tabela `[apim]` (ver o exemplo comentado já incluído nos três `deployment.toml`):

```toml
[apim.policy_sandbox]
enable = true
```

**Atenção:** declarar `[apim.policy_sandbox]` **antes** de `[apim]` causa um
`StackOverflowError` no parser TOML (`net.consensys.cava.toml`) por recursão infinita —
é por isso que o bloco precisa vir depois.

Se o Gateway que vai rodar os testes for uma instância separada do Control Plane
(recomendado — nunca aponte o sandbox para um Gateway de produção), configure também
`sandbox_url` no ambiente (`Environment`) do Control Plane, por exemplo:

```toml
sandbox_url = "https://localhost:9444/api/am/gateway/v2"
```

## Limitações conhecidas

(detalhes completos em [`STATUS.md`](./STATUS.md), seção "Pendências")

- O sandbox não passa pelos handlers do APIM (sem contexto `api.ut.*`; pode ser simulado
  via `extraProperties`), e analytics é desligado durante a execução.
- Só funcionam ambientes definidos em configuração, com `service_url`/`sandbox_url`.
- `endpoint key=` e `To` dinâmico não são mockáveis (viram warnings).
- Captura de logs é aproximada (via `LogReplicaMediator`); `level=full` não reproduz o
  envelope completo do log real.
- `flow` `response`/`fault` só executam como sequência simples, com warning.
- Testes de integração (`integration-v2`) e o bump final de versões/build completo das
  features ainda não foram feitos (ver STATUS.md, pendências 8 e 9).

## Outros documentos nesta pasta

- [`STATUS.md`](./STATUS.md): histórico detalhado de progresso, decisões e testes
  executados, por fase e por sessão.
- [`CONTRACT-cp-gateway.md`](./CONTRACT-cp-gateway.md): contrato de request/response entre
  o Control Plane e o Gateway para `/policy-sandbox/execute`.
- [`PLAN.md`](./PLAN.md): plano original aprovado para a feature.
- `scripts/`: scripts de desenvolvimento usados durante a implementação (e2e do Gateway,
  smoke test de UI com Playwright, patches de hot-deploy e tasks do VS Code). Os caminhos
  absolutos `c:\workspace\...` nesses scripts são específicos desta máquina de
  desenvolvimento — ajuste-os antes de reutilizar em outro ambiente.
