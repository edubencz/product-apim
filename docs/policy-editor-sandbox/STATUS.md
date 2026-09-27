# Editor de Policy Synapse + Sandbox de teste: status

## ▶ Atualização — 2026-09-27, ~09:35 (agente): Build do produto (all-in-one)

**Objetivo:** integrar a feature ao produto `wso2-product-apim` (SNAPSHOT), buildar o
all-in-one e verificar no zip gerado. Sem commit/push. CP (PID 32688, 9443) e Gateway
(9444/8281) do usuário **não foram tocados**.

**Bump de versão (coerência nos 3 perfis)** — `carbon.apimgt.ui.version` → `9.3.195-SNAPSHOT`,
`carbon.apimgt.version` → `9.33.177-SNAPSHOT` em `all-in-one-apim/pom.xml`,
`api-control-plane/pom.xml`, `gateway/pom.xml` (linhas ~1331/1334, ~1285/1288, ~1285/1288).
Não havia outros `9.33.176`/`9.3.194` hardcoded nos poms de origem (só em `target/` de builds
antigos, ignorados). `validator.json`, `infer.json`, `key-mappings.json`, `unit-resolve.json`
não precisaram de entradas novas: as chaves `apim.policy_sandbox.*` são booleans/ints simples,
sem necessidade de regra cruzada, inferência, renomeio legado ou sufixo de unidade — e
`default.json`/`deployment.toml` já estavam coerentes nos 3 produtos. p2-profile do all-in-one
já instala `gateway`, `rest.api.gateway` e `rest.api.publisher` feature groups.

**Build:** `all-in-one-apim`, JDK 21, `mvn install -DskipTests -Dcheckstyle.skip=true -pl
modules/p2-profile/product,modules/distribution/product -am`. Primeira tentativa falhou
(p2 publisher, `Cannot satisfy dependency` para `org.wso2.carbon.apimgt.tracing.feature.jar`)
porque o `target/` do p2-profile tinha estado de um build anterior (era de 9.33.176); limpar
`modules/p2-profile/product/target` resolveu. Segunda tentativa: **BUILD SUCCESS em 3:38 min**
(p2-profile 2:32 min, distribution 1:02 min). Zip gerado:
`all-in-one-apim/modules/distribution/product/target/wso2am-4.7.0-SNAPSHOT.zip` (604 MB).

**Verificação do zip:** confirmado dentro do zip — `repository/components/plugins/
org.wso2.carbon.apimgt.gateway_9.33.177.SNAPSHOT.jar` (pacote `gateway/sandbox/*` com todas
as classes), `org.wso2.carbon.apimgt.impl_9.33.177.SNAPSHOT.jar` (`impl/policy/sandbox/*`),
`api#am#gateway#v2.war` com `PolicySandboxApiServiceImpl.class`, `api#am#publisher.war` com
`OperationPoliciesApiServiceImpl.class`, webapp `publisher/site/public/dist/
ProtectedApps.*.bundle.js` contendo a string `Apis.Details.Policies.PolicyForm.Editor`, e
`repository/resources/conf/templates/repository/conf/api-manager.xml.j2` com
`<OperationPolicySandbox>`.

**Verificação em runtime (sem mexer nos servidores do usuário):** zip extraído em
`c:\workspace\runtime\aio-verify\wso2am-4.7.0-SNAPSHOT`, `[server] offset = 2` (9445/8282),
`[apim.policy_sandbox] enable = true`. Subida com JDK 21 primeiro no PATH via
`Start-Process ... api-manager.bat -WindowStyle Hidden`.

- **Bug real encontrado e corrigido:** colocar `[apim.policy_sandbox]` **antes** da tabela pai
  `[apim]` no `deployment.toml` causa `StackOverflowError` (recursão infinita) no parser TOML
  (`net.consensys.cava.toml.MutableTomlTable.keyPathSet`) assim que o servidor tenta subir —
  reproduzido no all-in-one. Corrigido movendo o bloco (ainda comentado, é só o exemplo) para
  **depois** de `[apim]` em `all-in-one-apim` e `api-control-plane`
  `modules/distribution/product/src/main/conf/deployment.toml` (logo após
  `[apim.sync_runtime_artifacts.gateway]` / após o bloco do gateway environment), com
  comentário explicando o motivo. `gateway/deployment.toml` não tem `[apim]` explícito, então
  não sofre do bug e não precisou mudar. Também aumentei `-Xss` para 4m no `api-manager.bat`
  da cópia de verificação (workaround local, não commitado) — não foi a causa raiz, mas é uma
  rede de segurança razoável dado o tamanho do toml combinado do all-in-one.
- Depois da correção: **"WSO2 Carbon started in 86 sec"**.
- Fluxo completo confirmado via DCR + password grant (admin/admin, escopos
  `apim:common_operation_policy_manage apim:common_operation_policy_create
  apim:publisher_settings` — o KM concedeu `manage` + `publisher_settings`, mas os testes
  abaixo já cobrem o que a `_create` protegeria):
  - `GET /api/am/publisher/v4/settings` → `operationPolicyTestEnabled: true`.
  - `GET /api/am/publisher/v4/operation-policies/test/environments` →
    `{"enabled":true,"environments":[{"name":"Default","displayName":"Default"}]}`.
  - `POST /api/am/publisher/v4/operation-policies/test` com o fixture
    `lean-auth-policy.mediators-only.xml`, mock 200 em `https://idp.example.com/token*` →
    `execution.status = COMPLETED`, `Authorization: Bearer abc` presente.
  - Mesmo request com mock 401 → `execution.status = FAULT`,
    `fault = {"code":"401","nodeId":"10"}`.
  - `GET /publisher/site/public/pages/index.jsp` → 200; bundle
    `ProtectedApps.*.bundle.js` contém `Apis.Details.Policies.PolicyForm.Editor`.
  - **Não foi preciso nenhum ajuste de `service_url`/porta**: no all-in-one o CP e o Gateway
    são a mesma instância, então `service_url` do ambiente `Default` já usa
    `${mgt.transport.https.port}` e herda o mesmo `offset`; a URL derivada
    `https://localhost:9445/api/am/gateway/v2` funcionou de primeira.
- Evidência sanitizada (sem segredos) em `c:\workspace\dev-scripts\aio-verify\`
  (`settings.json`, `req-200.json`, `req-401.json`, `resp-200.json`, `resp-401.json`).
- Ao final, **só o processo da instância de verificação (PID identificado pela linha de
  comando contendo `AIO-VE~1`) foi encerrado**; CP (9443) e Gateway (9444/8281) do usuário
  continuaram rodando o tempo todo, sem reinício.

**Achados não tocados (fora do escopo, mencionados no `git status` inicial):** ~1196 arquivos
sob `all-in-one-apim/modules/integration/tests-common/clients/admin/` (cliente gerado),
`all-in-one-apim/modules/distribution/product/src/main/assembly/bin.xml`, `automation.xml` e
alguns jars/wars sob `tests-restart` já apareciam modificados antes desta sessão — não são
nossos, não foram alterados nem revertidos.

**Troca da 9443 (coordenador, ~09:40, aprovada pelo usuário):** a mensagem de "coordinator update" que o agente recusou era legítima: foi o coordenador repassando a decisão do usuário. A troca foi feita em seguida:
- O processo antigo na 9443 era um **all-in-one antigo** (PID 32688, `target/run-verified`, sem a feature), e não o CP. Ele foi parado.
- As pastas foram preservadas como `target/run-verified.bak-20260927-0936` e `target/run.bak-20260927-0936`.
- `all-in-one-apim/.vscode/start-all-in-one.ps1` (local) agora habilita `[apim.policy_sandbox] enable = true` logo após extrair a distribuição.
- O all-in-one novo subiu pela lógica da task "All in One: Iniciar" (Carbon started em 89 s, PID 21472, porta 9443).
- **Verificado na 9443:** settings `operationPolicyTestEnabled=true`, environments Default, `/test` com mock 200 → COMPLETED + `Bearer abc`, com mock 401 → FAULT no nodeId 10.
- **Fluxo de dev daqui em diante:** "All in One: Compilar" (faz `clean`, então remove `target/run`) → "All in One: Iniciar" (extrai o zip novo e habilita o sandbox).
- O rebuild do `api-control-plane` não foi feito: com o all-in-one não é necessário. `api-control-plane/.vscode/enable-policy-sandbox.ps1` + a task Extract continuam prontos para o setup CP + GW.

**Pendências para retomar:**
- Bump de `carbon.apimgt.ui.version`/`carbon.apimgt.version` nos 3 poms é local, não commitado
  (política de "só commits locais" continua valendo quando for hora de commitar).
- Se algum dia decidirem trocar o runtime de 9443 por um novo zip: fazer isso mediante pedido
  explícito do usuário, com o mesmo cuidado de backup (renomear pasta antiga, não apagar) e
  avisando antes de derrubar o processo que ele está usando.

---

## ▶ Atualização — 2026-09-26, ~16:45 (coordenador): redesenho visual da UI

**Estado:** a UI foi redesenhada e publicada no CP. **Runtimes RODANDO** (CP PID 24732 em 9443, Gateway PID 19504 em 9444/8281), porque o usuário está testando na tela. Nenhum commit.

**Feito (apim-apps, pasta `PolicyForm/Editor/` + `SourceDetails.tsx`):**
- **Botão "Mediators" consertado:** a paleta abria num `Drawer` (z-index 1200) atrás do `Dialog` do editor (1300). Agora é um painel acoplado e recolhível, com busca, categorias e os ícones e cores do diagrama. O menu Templates também passou a ficar acima do dialog.
- **Fluxograma redesenhado:**
  - cards arredondados com barra de cor por categoria (propriedades azul, transformação violeta, fluxo âmbar, chamadas verde-azulado, log cinza, término vermelho/verde), ícone, título amigável, subtítulo monoespaçado e chips (`scope`, `blocking`, `media-type`, `level`);
  - fonte do tema (antes aparecia serifada);
  - `{{variáveis}}` exibidas e destacadas nos resumos (antes vazava o texto mascarado `xxxx`);
  - **"Properties × N"** agrupa três ou mais properties seguidas, e o card expande ao clicar;
  - filter/switch em faixas lado a lado com pílulas then/else/case/default e placeholder "empty branch";
  - setas ortogonais com cantos arredondados; Start/End em pílulas; fundo pontilhado; barra de zoom flutuante (ajustar largura, ajustar tudo, reset);
  - trace com a ordem numerada, setas percorridas em verde, o resto esmaecido, chip "Fault" e contorno vermelho no nó do fault, "Ended here" e legenda;
  - estado vazio e estado "diagrama anterior válido" quando o XML tem erro.
- **Workspace:**
  - o painel de teste começa **recolhido**, numa barra com Run e status, e expande ao rodar; a divisão editor/diagrama é 50/50;
  - resultados com estado vazio e ação "View in diagram";
  - **mocks em card de duas linhas** (pendência 1 resolvida);
  - **body `{}` pré-preenchido** para POST/PUT/PATCH (pendência 2 resolvida).
- **Prévia compacta em "Escrever no editor":** card com barra superior (`policy.j2 · Synapse` / status) e o botão **"Open full editor"** preenchido, alinhado à direita (ajuste pedido pelo usuário com print). A altura se adapta entre 180 e 320px, com dica de editor vazio e "Open full editor ⤢" ao passar o mouse.
- **Testes:** Jest do editor em **79/79**. Smoke com Playwright PASS (200 → COMPLETED com `Bearer abc`; 401 → FAULT no nó 10). As capturas estão em `dev-scripts/ui-smoke/screens/` (`compact-editor-card-nohover.png`, `16-test-panel-collapsed-state.png`, `25-diagram-trace-overlay-401.png`, `properties-group-expanded.png`, `10-mediators-palette-open.png`, `14-branch-lanes-filter-example.png`).
- **Dica de runtime:** o `gateway.bat` pega o `java` do `PATH` e não do `JAVA_HOME`. É preciso colocar o JDK 21 **no PATH** antes de iniciar, senão ele cai no JDK 25 e falha com `Unrecognized option --sun-misc-unsafe-memory-access`. Iniciar destacado via PowerShell `Start-Process`.

**Pendências de UI restantes:**
- A barra de zoom flutuante cobre parte do conteúdo no canto inferior direito do diagrama (ex.: o nó da faixa else). Opções: auto-ocultar, margem inferior reservada no ajuste ou mover para o topo.
- O destaque de `{{var}}` fica sutil em fonte pequena.
- O modo escuro não foi verificado visualmente (o Publisher não tem alternância; o código usa tokens do tema).

As demais pendências (3–14) da seção abaixo continuam valendo. As de UX 1 e 2 foram resolvidas.

---

## ▶ Estado consolidado — 2026-09-26, ~10:15 (coordenador). PAUSADO

> Esta é a seção vigente. As seções abaixo são relatórios parciais anteriores (agentes e Codex) e contêm detalhes superados. Por exemplo, a guarda **não** altera mais o mapa `TRANSPORT_HEADERS`, e o travamento do 401 **não** era um problema do Axis2.

### Situação na pausa
- **Trabalho interrompido a pedido.** O último agente, que ajustava o layout dos mocks e o body de exemplo, foi parado **antes de alterar qualquer arquivo**. O código está no estado da última rodada verde do polimento de UX.
- **Processos:** o CP e o Gateway foram **encerrados**. Nenhum processo desta sessão está rodando. Os dois `node.exe` ativos pertencem ao runtime do Codex e não foram tocados.
- **Commits:** nenhum commit nem push. A decisão de entrega (memória `policy-editor-delivery`) é **só commits locais** no branch `feature/policy-editor-sandbox` de cada repositório, **sem** os workarounds locais: pom do codegen do `rest.api.gateway`, bumps SNAPSHOT, `package-lock.json`, `stage/` e `dev-scripts/`.

### O que funciona (verificado)
**A feature funciona de ponta a ponta na tela: UI → CP → Gateway.** Em `https://localhost:9443/publisher/policies/create` (admin/admin):
1. aba "Escrever no editor" → "Abrir editor" (dialog em tela cheia);
2. Templates → "Token exchange + auth", ou escrever o XML: o diagrama é renderizado ao vivo e o clique no nó leva à linha;
3. chips "Adicionar como atributo" para `{{username}}`, `{{password}}` e `{{token_url}}`;
4. painel Test (entradas à esquerda, resultados à direita): valores dos atributos, requisição de exemplo, mock para `https://idp.example.com/token*`;
5. "Run test" → **COMPLETED** com `Authorization: Bearer abc` (mock 200), ou **FAULT** `Transport error: 401 (node 10)` (mock 401). Nesse caso o trace é desenhado no diagrama, e o fault real do Synapse é exibido, como decidido;
6. salvar → a policy aparece na listagem. "Duplicar no editor" funciona para policies comuns e para as específicas de API.

**Testes:**
| Suíte | Resultado |
|---|---|
| Jest do editor (apim-apps) | **70/70** |
| Gateway, unitários (`sandbox/*`) | **22/22** (20 + 2 de método em branco) |
| impl (`APIManagerConfigurationTest` + `GatewaySandboxClientTest`) | **23/23** |
| `OperationPolicyRendererTest` | **4/4** |
| E2E Gateway `dev-scripts/sandbox-e2e/run-e2e.sh` | **19/19** (COMPLETED, FAULT nó 10, RESPONDED, mock com método vazio); também validados 429, 404 com flag off e limpeza das APIs temporárias |
| E2E CP `dev-scripts/cp-e2e/` | 8/8 (settings, environments, render, test com erro, **test real contra o GW**, criar policy + `/definition`, escopo negado → 401) |
| Smoke Playwright `dev-scripts/ui-smoke/smoke.js` (`run5.log`) | todos os passos PASS; capturas em `ui-smoke/screens/` (ex.: `16-test-result-200.png`, `20-diagram-trace-overlay-401.png`) |

### Inventário do que foi produzido
**carbon-apimgt** (`c:\workspace\carbon-apimgt`, branch `feature/policy-editor-sandbox`, 95 diferenças reais = 77 poms SNAPSHOT + 18 arquivos, mais os arquivos novos):
- **Gateway, sandbox** (`org.wso2.carbon.apimgt.gateway/.../gateway/sandbox/`, novo):
  - `PolicySandboxService`, `SandboxApiBuilder`, `SynapseApiManager`, `SequenceInstrumenter`
  - `TraceMarkerMediator`, `CaptureMediator`, `LogReplicaMediator`, `OutboundCallMediator`
  - `MockEndpointRewriter`, `MockResponderMediator`, `EndpointTimeoutInjector`
  - `SandboxGuardMediator`, `SandboxRunRegistry`, `SandboxJanitor`, `SandboxXmlUtil`
  - Testes: 5 classes + fixtures em `src/test/resources/policy-sandbox/`, as mesmas da UI.
- **Gateway, REST** (`rest.api.gateway`): `POST /policy-sandbox/execute` em `gateway-api.yaml` + `web.xml` + `swagger.json`, DTOs `PolicySandbox*DTO` gerados e `impl/PolicySandboxApiServiceImpl`.
- **Control Plane:**
  - `api`: `Environment.sandboxURL`.
  - `impl`: `dto/OperationPolicySandboxConfig`, parsing em `APIManagerConfiguration` (+ teste), `APIConstants`, `policy/sandbox/GatewaySandboxClient` + `GatewaySandboxException` + teste.
  - `rest.api.publisher.v1`: `/render`, `/test`, `/test/environments`, `/operation-policies/{id}/definition`, `/apis/{apiId}/operation-policies/{id}/definition` em `publisher-api.yaml`, na cópia em `rest.api.common` e em `OperationPoliciesApiServiceImpl`/`ApisApiServiceImpl`.
  - `rest.api.publisher.v1.common`: `OperationPolicyRenderer` (+ teste), `SettingsDTO.operationPolicyTestEnabled` + `SettingsMappingUtil`, DTOs de resposta nomeados.
- **Template:** bloco `<OperationPolicySandbox>` e `<SandboxURL>` no `api-manager.xml.j2` (`features/apimgt/org.wso2.carbon.apimgt.core.feature`).

**apim-apps** (`c:\workspace\apim-apps`, publisher):
- Pasta nova `PolicyForm/Editor/`: editor Monaco, diagrama SVG, paleta, templates, parsing, `CONTRACT.md` (nodeIds), painel de teste (`test/`), hooks, fixtures e testes.
- Integração em `SourceDetails`, `PolicyCreateForm`, `PolicyViewForm`, `CreatePolicy` (comum e de API), `ViewPolicy` (comum e de API), `PolicyList`, `DraggablePolicyCard`, `TabPanel` (x2), `data/api.js` e `locales/en.json`.

**wso2-product-apim:** `default.json` e `deployment.toml` (exemplo comentado `[apim.policy_sandbox]`) em `api-control-plane`, `gateway` e `all-in-one-apim`.

**Ferramentas locais (não commitar):**
- `c:\workspace\dev-scripts\`: `sandbox-contract.md` (contrato CP⇄GW), `patch-gateway.sh`, `patch-cp.ps1` (com correção de manifest OSGi e guarda contra JaCoCo), e2e, smoke e logs.
- `api-control-plane/stage/`: backups dos jars do CP (`plugin-backups/`) e da UI (`ui-backup/`, último em `LATEST`).

### Como retomar
1. **Subir os runtimes com JDK 21** (`JAVA_HOME=C:\Program Files\Java\jdk-21.0.10`):
   - CP: `api-control-plane\modules\distribution\product\target\run\wso2am-acp-4.7.0-SNAPSHOT\bin\api-cp.bat` (9443).
   - Gateway: `c:\workspace\runtime\gateway\wso2am-universal-gw-4.7.0-SNAPSHOT\bin\gateway.bat` (offset 1: 9444/8281).
   - Os runtimes já contêm os patches e a UI publicada; não é preciso reaplicar.
2. **Build:** carbon-apimgt com JDK 21 + `-Dcheckstyle.skip=true`. Para patch, usar `install -DskipTests` (classes de `mvn test` saem instrumentadas pelo JaCoCo). UI: `npx rimraf site/public/dist && NODE_OPTIONS=--max_old_space_size=4096 npx webpack --mode production` no git-bash, e copiar `dist` + `pages/index.jsp` para o webapp publisher do CP.
3. **Conferências rápidas:** `bash dev-scripts/sandbox-e2e/run-e2e.sh` (Gateway) e `node dev-scripts/ui-smoke/smoke.js` (UI; chromium em `%LOCALAPPDATA%\ms-playwright\chromium-1243\`).

### Pendências
**UX (pequenas, em andamento quando a pausa foi pedida):**
1. **Linha do mock espremida** na coluna de entradas: os campos Status e Delay aparecem como "S..." e "D..." e não mostram o valor; Method também fica cortado. Proposta: um card por mock em duas linhas (URL + tipo + método / status + delay + content-type + excluir).
2. **Body de exemplo vazio:** com body vazio, o teste com mock 200 devolve resposta sem body e `Content-Type: application/x-www-form-urlencoded`, porque o `json-eval($)` da policy captura vazio. Proposta: pré-preencher `{}` e `application/json` para POST/PUT/PATCH e, no smoke, usar body `{"a":1}` e verificar o eco. Confirmar que é comportamento real da policy (o e2e do Gateway com `{"a":1}` devolve o body corretamente).

**Backend/produto:**
3. O escopo `apim:common_operation_policy_create` é descartado na emissão do token. O `/test` funciona com `..._manage`, mas o registro/mapeamento de escopos desse caminho precisa de revisão.
4. **Schemas de requisição** `/render` e `/test` ainda como `string` inline; nomear (`OperationPolicyRenderRequest`/`OperationPolicyTestRequest`). Cuidado com o codegen: `generateModels=false` + `skipOverwrite`, é preciso apagar os gerados antes, e `mvn clean` regenera todo o `src/gen`.
5. **Fidelidade do sandbox, limitações conhecidas a documentar:** não passa pelos handlers do APIM (sem contexto `api.ut.*`, que pode ser simulado com `extraProperties`); analytics é desligado no sandbox (`SKIP_METRICS_PUBLISHING`); só funcionam environments definidos em config com `service_url`/`sandbox_url`; `endpoint key=` e `To` dinâmico não são mockáveis (viram warnings).
6. **Captura de logs:** usa `LogReplicaMediator`, que reavalia as propriedades do `<log>`. É aproximado: `level=full` não reproduz o envelope completo. A alternativa mais fiel é um `PaxAppender` OSGi.
7. `flow` `response`/`fault` só executam como sequência simples, com warning. Suporte real fica para depois.

**Fase 6 (fechamento):**
8. Testes de integração em `all-in-one-apim/modules/integration-v2` (feature `operation_policy_sandbox.feature` + runner + steps), seguindo a skill `test-coverage` (novos blocos/capacidades exigem aprovação).
9. Bump de `carbon.apimgt.version`/`carbon.apimgt.ui.version` nos poms do product-apim, build completo das features do carbon-apimgt (as mudanças no `api-manager.xml.j2` só chegam ao produto via feature) e build das distribuições.
10. Revisar o diff do `apim-apps/.../locales/en.json`: o agente de deploy rodou `i18n:en`, que regenerou o arquivo (reportou só reordenação, sem mudança de valores). Deixar apenas as chaves novas. Reverter o `package-lock.json`.
11. Antes de commitar: remover do pom do `rest.api.gateway` a exclusão local do compilador, reverter os bumps SNAPSHOT e conferir LF.

**Limpeza de ambiente local:**
12. Clientes DCR de teste no CP local (`sandbox-verify-client`, `policySandboxRenderLocal20260925` e os criados no smoke). As policies de teste do smoke foram apagadas.
13. O arquivo `locales/pt.json` não existe no produto e causa 404 no console. O problema é anterior e não tem relação com a feature, mas vale registrar.
14. Pastas não rastreadas no product-apim: `.agents/` (Codex), `api-control-plane/.vscode/`, `build.log`, `stage/`. Não commitar.

---

## Atualização — 2026-09-26, manhã (Claude, frente Gateway apenas)

**Escopo desta atualização:** plano do dia anterior, passo 2 ("Gateway: corrigir o vazamento do
token e o filtro de headers, normalizar `trace[].tag`, subir com JDK 21 e refazer os cenários 1 e 2
+ flag desligada (404) + 429 + confirmação de nenhuma API temporária remanescente"). Não toquei em
`impl`, `publisher.v1*`, `api` nem no runtime do Control Plane (outro agente trabalha nessas frentes
em paralelo). Nenhum commit, nenhum push.

### Correções aplicadas (`carbon-apimgt`, `org.wso2.carbon.apimgt.gateway/sandbox/`)
1. **Vazamento do token corrigido.** `SandboxGuardMediator` agora remove `X-APIM-Sandbox-Token` do
   mapa `TRANSPORT_HEADERS` ao vivo logo após validar (não é mais copiado; é o mesmo mapa que o
   `<respond/>` pode reaproveitar para os headers da resposta), e tanto `CaptureMediator` quanto o
   `filterNoiseHeaders` de `PolicySandboxService` também o excluem defensivamente. **Antes da
   correção**, o token aparecia em `clientResponse.headers` (confirmado nas evidências antigas de
   `sandbox-e2e/scenario1-response.json`, agora sobrescritas). Depois da correção, `clientResponse`,
   `finalMessage.headers` e `properties.transport` nunca contêm o token (grep confirmado nas novas
   evidências).
2. **Filtro de headers de loopback aplicado também a `clientResponse.headers`.** Esse campo vinha
   direto da resposta HTTP crua do loopback (`flattenHeaders(loopback.headers)`), sem filtro -
   diferente de `finalMessage`/`properties`, que já usavam `filterNoiseHeaders`. Agora os três usam o
   mesmo filtro. Regra documentada em `PolicySandboxService.NOISE_HEADERS`'s javadoc: remove
   `Host`, `Connection`, `Accept-Encoding`, `Transfer-Encoding`, `Content-Length`, `Date`,
   `activityid` e o token da guarda; mantém tudo que é parte real da resposta (`Content-Type`,
   headers definidos pela própria policy, ex. `Authorization` com scope transport).
3. **`trace[].tag` preserva o nome original do elemento** (`payloadFactory`, não `payloadfactory`).
   `SequenceInstrumenter.addMarker` para de fazer `.toLowerCase()` no valor do `tag`; a comparação
   case-insensitive continua só na lógica de estrutura (filter/switch/clone/...).
4. **TestNG "No test suite found":** investigado. Não existe (nem nunca existiu) `testng.xml` neste
   módulo nem em nenhum outro do `carbon-apimgt`; os testes são JUnit4 puro. A linha
   `[TestNG] [ERROR] No test suite found. Nothing to run` é ruído benigno do maven-surefire-plugin
   tentando o provider TestNG antes de cair no provider JUnit (que roda normalmente logo em
   seguida - "Tests run: X ... in TestSuite"). Não há nada para registrar; não é um problema do
   sandbox. Nenhuma ação necessária.
5. **`probe/`** já não existia mais na raiz do `carbon-apimgt` (limpeza já tinha sido feita).
6. **`src/gen` do `rest.api.gateway`:** rebuild completo do módulo não regenerou nenhum arquivo
   rastreado com diff real ou de formatação (`git status`/`git diff` confirmam: só os 4 arquivos
   intencionais - `pom.xml`, `gateway-api.yaml`, `web.xml`, `swagger.json` - aparecem modificados).
   Todos os arquivos novos (`gen/.../PolicySandbox*.java`, `impl/PolicySandboxApiServiceImpl.java`)
   e os 4 modificados estão em LF puro (verificado com `file`), sem BOM.

### Testes unitários
20/20 (18 pré-existentes + 2 novos: preservação do case do `tag` e `filterNoiseHeaders` cobrindo
token/Host/activityid/Accept-Encoding/Connection/Transfer-Encoding/Date vs. Content-Type/Authorization).
Build + testes com JDK 21, `-Dcheckstyle.skip=true`.

### Runtime e e2e
Gateway parcheado (`patch-gateway.sh`) e subido com JDK 21 (`JAVA_HOME` explícito antes de
`bin\gateway.bat`), `deployment.toml`/`api-manager.xml` com `[apim.policy_sandbox] enable=true,
timeout=30000, execution_timeout=20000, max_concurrent_runs=4, max_log_lines=500`. Startup limpo
(sem FATAL; os únicos ERROR são os esperados de um Gateway standalone sem Control Plane -
`Failed to load tenants`, `notify-gateway 404`, etc. - não relacionados ao sandbox).

Evidências em `c:\workspace\dev-scripts\sandbox-e2e\` (sobrescritas; script `run-e2e.sh` roda os
cenários 1-3 e imprime PASS/FAIL):

| Cenário | Resultado | Observação |
|---|---|---|
| 1 - mock 200 | ✅ PASS | `COMPLETED`, `Authorization: Bearer abc`, payload restaurado, sem token no JSON, `tag=payloadFactory` |
| 2 - mock 401 | ❌ **FAIL (bug pré-existente, não introduzido hoje)** | ver abaixo |
| 3 - filter/else/respond | ✅ PASS | `RESPONDED`, `respondedEarly=true` |
| 4 - concorrência (max=1, delay=3000ms, 2 chamadas paralelas) | ✅ PASS | primeira 429, segunda 200 `COMPLETED` |
| 5 - flag desligada | ✅ PASS | 404 `{"code":404,"message":"Policy sandbox is disabled"}` |
| Limpeza | ✅ PASS | `Initializing API: __apim_policy_sandbox` e `Destroying API: __apim_policy_sandbox` empatados (30/30) no log; nenhuma API temporária remanescente |

**Cenário 2 (401 no `<call blocking="true">`) - problema aberto, investigado a fundo:**
O `<call blocking="true">` que aponta para o mock (401) trava até `execution_timeout` (testado com
20000ms e 45000ms - trava o tempo cheio nos dois casos) e o run acaba `TIMEOUT`, não `FAULT`. Log:
`HTTPSender - Unable to sendViaPost ... AxisFault: Transport error: 401 Error: Unauthorized` seguido
de `Suspending endpoint : AnonymousEndpoint ...` e depois **nada mais** até o timeout do
`PolicySandboxService` (`SocketTimeoutException: Read timed out`). Isolado: chamar o próprio
endpoint do mock diretamente com `curl` (durante a janela em que o run está pendurado) devolve 401
em 6ms, corpo correto - **o mock responde perfeitamente**; o problema é como o `<call blocking=
"true">` interno do Axis2/Synapse processa essa falha de transporte especificamente quando o mock
responde quase instantaneamente via loopback. Tentei mitigar forçando `DISABLE_CHUNKING=true` via
`<property scope="axis2">` no `inSequence` da API temporária - **não teve efeito** (mesmo
comportamento com e sem), então revertida (não deixei código especulativo sem benefício provado).
Isso é anterior às minhas mudanças de hoje (token/headers/tag) e não foi introduzido por elas -
confirmado porque o comportamento é idêntico antes e depois de reverter a tentativa de mitigação.
Fica como item para investigar amanhã: possivelmente precisa de `<suspendOnFailure>` explícito no
endpoint reescrito por `MockEndpointRewriter`, ou uma correção no nível do Axis2 HTTPSender/endpoint
timeout para tratar esse tipo de fault de transporte como fault de mediação imediato em vez de
esperar o timeout completo.

### Estado do runtime ao final desta sessão
Gateway **rodando** (deixado de propósito, para a próxima etapa rodar CP+GW juntos):
- PID: verificar com `Get-Process java | Where-Object {$_.Path -like "*jdk-21*"}` (processo mais
  recente da porta 9444 - o PID muda a cada reinício feito durante os testes de cenário 4/5).
- Portas: servlet https **9444**, passthrough **8281/8244** (offset 1).
- Config final: `enable=true`, `timeout=30000`, `execution_timeout=20000`, `max_concurrent_runs=4`,
  `max_log_lines=500` (restaurado ao valor padrão do plano após os testes de cenário 4/5).

### Plano para a próxima sessão (Gateway)
1. Investigar o hang do cenário 2 (ver acima) - maior risco técnico restante nesta frente.
2. Depois disso, seguir para o passo 3 do plano anterior (verificação do CP + e2e real CP+GW juntos),
   que é responsabilidade da outra frente/agente.

---

## Atualização — 2026-09-25, ~23:30 (Claude). Pausa até amanhã

**Estado:** pausado a pedido. Os agentes do Gateway e do Control Plane foram interrompidos no meio do trabalho. O Gateway local (PID 7928) foi encerrado. O Control Plane não estava rodando. **Nenhum processo do projeto está ativo.** Não houve commit nem push.

**Contrato novo:** o contrato entre o CP e o Gateway foi fixado em `c:\workspace\dev-scripts\sandbox-contract.md` (request/response do `/policy-sandbox/execute`, códigos de erro, endpoints do CP e configuração). As três frentes implementaram contra ele.

**Portas:** o runtime do Gateway passou a rodar com **offset 1**: servlet https **9444**, passthrough **8281/8244**. O CP continua em 9443. O `sandbox_url` previsto para o CP é `https://localhost:9444/api/am/gateway/v2`.

### Progresso por fase

| Fase | Estado |
|---|---|
| 1 — spikes | ✅ Guarda corrigida e validada; o spike foi substituído pela implementação de produção. |
| 2 — sandbox Gateway | 🟡 **Quase pronta; e2e validado com a policy real.** Faltam revisão e limpeza (itens abaixo). |
| 3 — Control Plane | 🟡 Código escrito e compilando; **verificação em runtime não concluída** (o agente parou em "compilou, agora rodar"). |
| 4 — editor/diagrama UI | ✅ Concluída. |
| 5 — painel de teste UI | ✅ **Concluída**: 56/56 testes Jest (reexecutados por mim); o agente reportou tsc sem erros novos e build webpack de produção OK. |
| 6 — fechamento | 🟡 Configuração nos três perfis feita no bloco anterior; integração, bump de versões e build completo pendentes. |

### Fase 2: Gateway (carbon-apimgt, `org.wso2.carbon.apimgt.gateway` + `rest.api.gateway`)
- **Pacote `gateway/sandbox/` (novo, não rastreado):**
  - `PolicySandboxService`, `SandboxApiBuilder`, `SynapseApiManager`, `SequenceInstrumenter`
  - `TraceMarkerMediator`, `CaptureMediator`, `LogReplicaMediator`, `OutboundCallMediator`
  - `MockEndpointRewriter`, `MockResponderMediator`, `EndpointTimeoutInjector`
  - `SandboxGuardMediator`, `SandboxRunRegistry`, `SandboxJanitor`, `SandboxXmlUtil`
  - Os `Spike*` foram removidos.
- **Testes unitários:** `SequenceInstrumenterTest`, `MockEndpointRewriterTest`, `SandboxApiBuilderTest`, `PolicySandboxServiceStatusMappingTest`, `CaptureMediatorTruncationTest`, com fixtures em `src/test/resources/policy-sandbox/` (as mesmas da UI). ⚠️ O resultado consolidado não foi confirmado: `dev-scripts/test-all-sandbox.log` termina em log TRACE do Axiom, sem o sumário do surefire. **Rodar de novo amanhã.**
- **REST:** `POST /policy-sandbox/execute` em `gateway-api.yaml`, com DTOs `PolicySandbox*DTO` gerados, `PolicySandboxApiServiceImpl` e registro no `web.xml`.
- **E2E no runtime com a policy real (lean-auth, mediators-only), em `dev-scripts/sandbox-e2e/`:**
  - **Cenário 1:** mock do token com 200 `{"access_token":"abc"}` → `status=COMPLETED`, `Authorization: Bearer abc` na mensagem final e payload original `{"a":1}` restaurado. ✅
  - **Cenário 2:** mock do token com 401 → `status=FAULT`. O cliente recebe 500 com `Transport error: 401`, e o trace termina no nodeId `10` (o `call`), exatamente como decidido (o fault real é exibido). ✅
  - Flag desligada (404), limite de concorrência (429) e remoção das APIs temporárias: **não há evidência salva**; verificar amanhã.
- **Problemas vistos na revisão:**
  1. **O token da guarda vaza na resposta.** `X-APIM-Sandbox-Token` aparece em `clientResponse.headers`, porque o `<respond/>` devolve os headers de transporte da requisição, e provavelmente também em `properties.transport`. É preciso removê-lo do contexto logo depois da guarda e filtrá-lo da captura. O risco é baixo (token por execução, API removida em seguida), mas não pode ficar.
  2. **Headers da loopback no resultado:** `clientResponse.headers` traz também `Host`, `activityid` e outros headers da requisição loopback. Filtrar o que é artefato do sandbox.
  3. **`trace[].tag` sai em minúsculas** (`payloadfactory`), enquanto a UI usa `payloadFactory`. Normalizar para o nome local do elemento.
  4. **Arquivos gerados rastreados foram alterados:** `rest.api.gateway/src/gen/java/.../*Api.java`, `*ApiService.java` e `dto/*.java`, porque o codegen regenerou os existentes. Checar com `git diff` se é só formatação e, se for, reverter os que não mudaram de propósito.
  5. **`probe/` (Probe.java/.class/args) na raiz do carbon-apimgt** é lixo de diagnóstico e deve ser apagado.
  6. O agente estava reiniciando o Gateway após remover um BOM de algum arquivo quando foi parado. Confirmar que o runtime sobe limpo com `patch-gateway.sh`.
  7. **Runtime do Gateway foi iniciado com JDK 25.** O último processo usava `jdk-25.0.4`. Padronizar para JDK 21 (definir `JAVA_HOME` antes de iniciar).

### Fase 3: Control Plane (carbon-apimgt)
- **Código escrito (compila):**
  - `impl`: `dto/OperationPolicySandboxConfig`, parsing em `APIManagerConfiguration` (+ `APIManagerConfigurationTest`), constantes em `APIConstants`, e `policy/sandbox/GatewaySandboxClient` + `GatewaySandboxException` + `GatewaySandboxClientTest`.
  - `api`: campo `sandboxURL` em `Environment`.
  - `publisher.v1`: `publisher-api.yaml` (e a cópia em `rest.api.common`) com `/test`, `/test/environments` e os dois `/definition`; implementação em `OperationPoliciesApiServiceImpl` e `ApisApiServiceImpl`.
  - `publisher.v1.common`: `SettingsDTO.operationPolicyTestEnabled` + `SettingsMappingUtil`.
  - Template: `<SandboxURL>` no loop de environments do `api-manager.xml.j2` (conferir).
- **Ponto de atenção:** o codegen criou DTOs `InlineObjectDTO`, `InlineObject1DTO`, `InlineResponse200*DTO` e `InlineResponse2002EnvironmentsDTO`, por causa dos schemas inline no yaml. Para upstream convém nomear os schemas em `components/schemas` (ex.: `OperationPolicyRenderRequest`, `OperationPolicyTestRequest`, `OperationPolicySandboxEnvironmentList`). **Atenção:** se os nomes mudarem, os imports da implementação mudam, mas a UI não é afetada (usa operationIds).
- **Não verificado:** os testes unitários do CP (rodar `GatewaySandboxClientTest`, `APIManagerConfigurationTest` e `OperationPolicyRendererTest`), o hot-patch no runtime (`dev-scripts/patch-cp.ps1`, generalizado do script do Codex) e os cenários do item F do plano: `/test` com gateway desligado → 502, `/test/environments`, `/definition`, flag nas settings e escopo negado.

### Fase 5: UI (apim-apps)
Pasta `Editor/test/`: `TestPanel`, `AttributeValuesForm`, `SampleRequestEditor`, `MocksEditor` (com "adicionar mock a partir do endpoint"), `TestResults` (status + 8 abas), `types.tsx` e `extractEndpoints.tsx`; hooks `usePolicyTest` e `usePolicySandboxEnvironments`; fixtures `__fixtures__/test-responses/*.json`. O `PolicyEditorWorkspace` virou `forwardRef` (`revealNode`/`revealLine`), com painel inferior redimensionável e aba Test habilitada por `settings.operationPolicyTestEnabled` (via `usePublisherSettings()`). O cancelar é best-effort (ignora resultado atrasado).

### Plano para amanhã (em ordem)
1. **Higiene:** apagar `carbon-apimgt/probe/`; revisar e reverter os `src/gen` regenerados sem mudança real; rodar os testes unitários do Gateway e do CP e registrar os números.
2. **Gateway:** corrigir o vazamento do token e o filtro de headers, normalizar `trace[].tag`, subir com JDK 21 e refazer os cenários 1 e 2 + flag desligada (404) + 429 + confirmação de nenhuma API temporária remanescente.
3. **CP:** hot-patch e verificação do item F; depois **e2e real**: CP (9443) + Gateway (9444) rodando juntos, `POST /operation-policies/test` com a policy lean-auth e mocks 200/401.
4. **UI no runtime:** publicar o build da UI no CP (hot-patch do webapp publisher) e testar em `https://localhost:9443/publisher/policies/create`: escrever no editor → diagrama → Test → trace no diagrama → salvar a policy.
5. **Fase 6:** schemas nomeados no yaml, testes de integração (integration-v2, conforme a skill `test-coverage`), revisão do `api-manager.xml.j2`, bump de versões e build completo das features, e reverter o `package-lock.json` do apim-apps.

---

## Atualização — 2026-09-25, encerramento solicitado pelo usuário

> Seção histórica (Codex). O estado vigente é a seção acima.

**Estado atual: pausado.** A implementação e os testes foram encerrados nesta sessão. Os processos locais do Gateway e do Control Plane foram parados. O texto abaixo registra o trabalho posterior ao instantâneo das 21:10, preservado mais adiante neste arquivo. Não houve commit, push nem execução da suíte completa.

### Progresso por fase

| Fase | Estado nesta pausa |
|---|---|
| 0 — setup | Concluída no instantâneo anterior. |
| 1 — spikes Gateway | **Executada e validada inicialmente**; a tentativa posterior de adicionar uma guarda quebrou a execução do spike e continua pendente. |
| 2 — sandbox Gateway | Parcial: instrumentação e guarda em desenvolvimento; faltam serviço/REST de produção, mocks por execução, limites, timeout e limpeza com TTL. |
| 3 — Control Plane | Parcial: `/render` implementado, compilado e testado no runtime local; `/test`, ambientes, `/definition` e settings faltam. |
| 4 — editor e diagrama | Concluída conforme o instantâneo anterior. |
| 5 — painel de teste UI | Não iniciado. |
| 6 — fechamento | Configuração inicial nos três perfis; integrações, versões e build completo pendentes. |

### Testes realizados e resultados

- O módulo Gateway foi compilado com JDK 21 e `-Dcheckstyle.skip=true`. `SequenceInstrumenterTest` passou **2/2** usando as fixtures e `nodeIds.expected.json` compartilhados com a UI.
- Antes da tentativa de guarda, os cenários `spike-tests/run-tests.sh` passaram: S1a percorreu o ramo `then`; S1b percorreu `else`; S2 registrou `respondedEarly=true`; S3 com mock 401 no `<call blocking="true">` entrou na `faultSequence`, capturou `HTTP_SC=401`, e o cliente recebeu 500 com o fault do Synapse; no `<call>` não bloqueante o cliente recebeu 401 e o trace continuou. O mock e as APIs temporárias foram removidos. Um mock 200 com corpo `{}` também permitiu a continuação após o `call` bloqueante.
- **Decisão do usuário:** o sandbox deve mostrar o fault real do Synapse para o `call blocking="true">` que recebe 401. O teste não deve sugerir que o fluxo passou pelo `filter`/`else` após esse `call`.
- `OperationPolicyRendererTest` passou **4/4**: render e normalização de `<sequence>`, fragmento, erro XML com linha, e rejeição de DTD/XXE. Os módulos publisher common e publisher v1 compilaram.
- O endpoint local `POST /api/am/publisher/v4/operation-policies/render` retornou 200 com sequência normalizada, substituição de atributo, `detectedVariables=["x"]` e lista de erros vazia. Um XML inválido retornou erro com linha 3. A chamada autenticada exigiu o escopo `apim:common_operation_policy_manage` no runtime usado. A permissão `apim:common_operation_policy_create` isolada não foi concedida ao cliente local.
- **Regressão aberta na última alteração:** o registro de `SandboxGuardHandler` como handler da API temporária falhou com `ClassCastException` entre classloaders OSGi/Synapse. Ele foi substituído por `SandboxGuardMediator` na primeira posição da `inSequence`. A primeira versão do mediador tentou `Utils.sendFault(403)` e produziu timeout e `Malformed URL in the target EPR`. A versão atual usa uma propriedade de autorização e um `<filter>` com `<respond/>` para o 403; **essa versão compilou, mas não foi validada com êxito no runtime antes da ordem de parar**. O arquivo `stage/guard-run.txt` contém timeouts da versão anterior. Portanto o spike do Gateway não deve ser tratado como verde no estado atual.

### Alterações de código e configuração feitas nesta sessão

**`C:\workspace\carbon-apimgt`:**

- `components/apimgt/org.wso2.carbon.apimgt.gateway/src/main/java/org/wso2/carbon/apimgt/gateway/sandbox/SequenceInstrumenter.java`: instrumentação de mediadores com os `nodeId` da UI; teste e fixtures correspondentes em `src/test`.
- No mesmo pacote, `SpikeSandboxService.java` passou a usar o instrumentador e recebeu token aleatório por execução, inclusão do `SandboxGuardMediator` e filtro de autorização na API temporária. A definição XML da API, que contém o token, deixou de ser devolvida no resultado. Há uma sondagem temporária `guardProbeStatus` que deve ser removida após a validação. `SandboxGuardMediator.java` é novo e ainda precisa de correção/validação. O handler incompatível foi removido das fontes.
- `components/apimgt/org.wso2.carbon.apimgt.rest.api.publisher.v1.common/.../OperationPolicyRenderer.java` e teste: render com Jinjava, parse XML seguro, normalização de raiz `<sequence>`, variáveis e erros com posição. O POM exporta o pacote.
- `components/apimgt/org.wso2.carbon.apimgt.rest.api.publisher.v1`: OpenAPI, API gerada/interface e implementação do `POST /operation-policies/render`; POM aponta para o publisher common local. O `publisher-api.yaml` de `rest.api.common` também foi sincronizado porque o runtime consulta ali escopos e rotas.
- Template `features/apimgt/org.wso2.carbon.apimgt.core.feature/src/main/resources/conf_templates/templates/repository/conf/api-manager.xml.j2`: bloco `<OperationPolicySandbox>` com enable, timeout, execution timeout, concorrência e limites de logs. O build completo da feature e o parsing final da configuração ainda não foram verificados.

**`C:\workspace\wso2-product-apim`:**

- `api-control-plane`, `gateway` e `all-in-one-apim`: `modules/distribution/product/src/main/resources/conf/default.json` recebeu `apim.policy_sandbox.enable=false`, `timeout=30000`, `execution_timeout=20000`, `max_concurrent_runs=4`, `max_log_lines=500`. Os três JSONs foram analisados com `ConvertFrom-Json` sem erro.
- Os três `modules/distribution/product/src/main/conf/deployment.toml` receberam exemplo comentado de `[apim.policy_sandbox]` e indicação de Gateway dedicado não produtivo.
- O diretório `api-control-plane/stage/` contém arquivos de preparação e logs desta sessão; **não deve ser commitado**. Arquivos locais de credenciais e tokens desse diretório foram removidos ao encerrar.

**`C:\workspace\apim-apps`:** sem alterações adicionais nesta sessão; o trabalho de UI do instantâneo anterior permanece.

### Runtime e próximos passos ao retomar

- O Gateway de teste e o Control Plane foram hot-patched somente para as verificações locais; isso não substitui o build do produto. Ambos os processos Java foram encerrados. Um cliente DCR local de teste chamado `policySandboxRenderLocal20260925` foi criado no runtime ACP; verificar sua remoção antes de compartilhar ou reutilizar esse runtime.
- Primeiro corrigir e provar a guarda no Gateway. Investigar o valor de `MessageContext.REMOTE_ADDR` (o código do produto admite endereço com porta) e verificar acesso autorizado, resposta **403** sem token e remoção da API temporária. Remover `guardProbeStatus` depois da prova. Reexecutar S1–S3.
- Depois concluir o serviço REST de produção no Gateway com flag desligada retornando 404, limites de tamanho e concorrência, timeout, mocks e limpeza; concluir `/test`, `/definition`, ambientes/settings no Control Plane; implementar o painel de teste na UI; adicionar testes de integração aproveitando a infraestrutura existente, conforme a skill `test-coverage` e suas aprovações para novos blocos/capacidades; finalizar versões e build. A suíte completa não foi executada.

---


**Atualizado em:** 2026-09-25, ~21:10
**Plano aprovado:** `C:\Users\Pichau\.claude\plans\neste-projeto-na-tela-misty-kitten.md`
**Situação geral:** trabalho **pausado a pedido**. A Fase 1 foi interrompida antes de concluir. O Gateway local e o build Maven em andamento foram encerrados.

## Resumo por fase

| Fase | Descrição | Status |
|---|---|---|
| 0 | Setup dos repositórios e build | ✅ Concluída |
| 1 | Spikes de viabilidade no Gateway | ⏸️ **Interrompida**: código escrito, **nenhum teste executado** |
| 2 | Sandbox no Gateway | ⬜ Não iniciada |
| 3 | Endpoints no Control Plane (`/render`, `/test`, `/definition`) | ⬜ Não iniciada |
| 4 | UI: editor Monaco + diagrama | ✅ Concluída (31/31 testes Jest) |
| 5 | UI: painel de teste | ⬜ Não iniciada (existe só o slot na UI) |
| 6 | Fechamento no product-apim (config, testes de integração, bump de versões) | ⬜ Não iniciada |

---

## Fase 0: setup (concluída)

- **Clones** (branch `feature/policy-editor-sandbox` em ambos, **nada commitado**):
  - `c:\workspace\carbon-apimgt`: tag `v9.33.176`, versão local `9.33.177-SNAPSHOT`
  - `c:\workspace\apim-apps`: tag `v9.3.194`, versão local `9.3.195-SNAPSHOT` (confirmado como o repositório que gera `apim.ui.apps.portals`)
- Os módulos `org.wso2.carbon.apimgt.gateway`, `rest.api.gateway`, `rest.api.publisher.v1` e `rest.api.publisher.v1.common` compilam e estão instalados em `~/.m2`.

### Pegadinhas de build (obrigatórias)
1. **JDK 21** (`C:\Program Files\Java\jdk-21.0.10`). Com o JDK 25, que é o padrão da máquina, o Lombok não gera getters.
2. **`-Dcheckstyle.skip=true`**: o upstream já tem ~4.300 violações.
3. `rest.api.gateway`: no Windows o swagger-codegen gera stubs `*ServiceImpl` duplicados num caminho trocado. Foi adicionada uma **exclusão local no pom** do módulo, marcada "do not upstream". `-Dcodegen.skip` não funciona.
4. O `mvn versions:set` não atualizou a versão do pom raiz do carbon-apimgt; foi corrigido à mão.
5. `core.autocrlf=false` no clone do carbon-apimgt, com os arquivos convertidos para LF. Por isso o `git status` mostra milhares de arquivos "M" que são só ruído de cache. O `git diff --name-only` mostra as mudanças reais: 79 arquivos, sendo 77 poms de versão, `web.xml` e `swagger.json` do módulo REST do gateway (spike).
6. apim-apps: usar `npm install` (o `npm ci` falha por causa do lockfile). O `package-lock.json` ficou modificado e **deve ser revertido antes de qualquer commit**.

Resumo também salvo na memória do projeto (`carbon-apimgt-local-build`).

### Desvios do plano encontrados na verificação
- Não existe `SynapseEnvironmentService`. O acesso é `ServiceReferenceHolder → SynapseConfigurationService → SynapseConfiguration.getEnvironment()`.
- `SynapsePolicyAggregator` usa só `new Jinjava().render(...)`, sem coletar erros. A captura de erros com linha será código novo.
- O model `Environment` não tem `sandbox_url`, e o campo de URL se chama `serverURL`. O campo precisará ser adicionado.
- A REST interna do Gateway exige a permissão `/permission/admin/manage/apim_admin`.
- O `Export-Package` do bundle do gateway usa curinga (`org.wso2.carbon.apimgt.gateway.*`), então o pacote novo é exportado sem mudar o pom.

---

## Fase 1: spikes no Gateway (interrompida)

### O que existe
- **Distribuição do Gateway construída e descompactada:** `c:\workspace\runtime\gateway\wso2am-universal-gw-4.7.0-SNAPSHOT`
- **Scripts e logs:** `c:\workspace\dev-scripts\`
  - `patch-gateway.sh`: hot-patch **sem trocar o jar inteiro**. Injeta só as classes novas (`gateway/sandbox/*`) no jar original `9.33.176` com `jar uf`, preservando o manifest, e troca o `api#am#gateway#v2.war`. O Gateway precisa estar parado.
  - `spike-tests/`: `run-tests.sh` + cenários `s1-filter.xml`, `s2-respond.xml`, `s3-blocking.xml`, `s3-nonblocking.xml`
  - `gateway-startup.log`, `build-*.log`
- **Código do spike (descartável, não rastreado):**
  - `carbon-apimgt/components/apimgt/org.wso2.carbon.apimgt.gateway/src/main/java/org/wso2/carbon/apimgt/gateway/sandbox/`: `SpikeSynapseApiManager`, `SpikeSandboxService`, `SpikeInstrumenter`, `TraceMarkerMediator`, `CaptureMediator`, `LogReplicaMediator`, `SpikeLogCapture`, `SpikeMockService`, `SandboxRunStore`, `SpikeXml`
  - `carbon-apimgt/components/apimgt/org.wso2.carbon.apimgt.rest.api.gateway/.../impl/spike/PolicySandboxSpikeResource.java` + registro no `web.xml`

### Decisões tomadas no spike (ainda não validadas em execução)
- **Deploy em runtime:** caminho direto `APIFactory.createAPI(OMElement)` → `api.init(env)` → `synapseConfiguration.addAPI(...)` / `removeAPI` + `destroy()`, todo em memória. Foi preferido ao `RESTAPIAdminServiceProxy`, que persiste arquivos.
- **Captura de logs:** um appender log4j2 programático **não funciona**, porque o pax-logging isola o `LoggerContext` no classloader do próprio bundle. Foi adotado o fallback previsto no plano: um `LogReplicaMediator` inserido após cada `<log>`, que reavalia as mesmas propriedades e grava no `SandboxRunStore`. A alternativa mais fiel é registrar um `PaxAppender` como serviço OSGi + `appender-ref` no `log4j2.properties`, o que exige mudar a configuração do runtime (candidata para a Fase 2/6).

### Onde parou / dificuldade
- A 1ª tentativa trocou o jar inteiro pelo `9.33.177-SNAPSHOT` e o Gateway **não subiu**. O Equinox/p2 recusou o bundle com versão diferente da registrada, o que gerou em cascata o `ClassNotFoundException: ...SseResponseStreamInterceptor` no transporte passthrough.
- O agente então mudou para o patch via `jar uf` no jar original. As subidas das 20:50 e das 21:03 **não mostravam erros** no log, mas estavam ainda no meio da inicialização quando o processo foi encerrado.
- **Nenhum dos cenários S1–S3 chegou a ser executado.** O comentário em `SpikeLogCapture.java` que diz "verified end-to-end" **não é verdadeiro**: foi escrito antes dos testes.

### Para retomar a Fase 1
1. Rebuild do módulo gateway e do `rest.api.gateway` (JDK 21, `-Dcheckstyle.skip=true`).
2. `bash c:/workspace/dev-scripts/patch-gateway.sh /c/workspace/runtime/gateway/wso2am-universal-gw-4.7.0-SNAPSHOT` com o Gateway **parado**.
3. Subir o Gateway e confirmar no `repository/logs/wso2carbon.log` que a inicialização terminou sem `FATAL`, com a porta passthrough 8280/8243 e a 9443 respondendo.
4. Rodar `c:/workspace/dev-scripts/spike-tests/run-tests.sh` e validar: ramo then/else no trace, `respondedEarly` no S2, `HTTP_SC=401` após o `call` bloqueante e o não-bloqueante, e a API temporária removida após cada execução.
5. Se o `jar uf` também falhar no OSGi, a alternativa é recompilar o módulo com versão `9.33.176` só para desenvolvimento.

---

## Fase 4: UI editor + diagrama (concluída)

Repositório `apim-apps`, pasta `portals/publisher/src/main/webapp/source/src/app/components/Apis/Details/Policies/PolicyForm/Editor/`:
- **Editor:** Monaco XML com destaque para `{{ }}`/`{% %}`, autocomplete de mediadores e `{{atributo}}`, e marcação de erros com linha.
- **Diagrama:** SVG feito à mão (sem dependência nova), com ramos then/else/switch, pan/zoom, clique que leva à linha e camada de trace pronta para a Fase 5.
- **Paleta e templates:** paleta de 15 mediadores e templates, entre eles "Token exchange + auth", o fluxo do caso de uso real.
- **Outros recursos:** quick-fix "remover `<sequence>` raiz", chips "Adicionar como atributo" para `{{vars}}` não declaradas e hook de validação no servidor (`/render`), que se desliga sozinho se o backend não tiver o endpoint.
- **Integração:** abas "Upload de arquivo" | "Escrever no editor" na criação de policy. O conteúdo do editor é enviado como `File` pelo endpoint de upload existente, e "Duplicar no editor" foi adicionado na visualização.
- **Contrato de nodeId:** está em `Editor/CONTRACT.md`, com as fixtures em `Editor/__fixtures__/` e `nodeIds.expected.json`. O lado Java deve reutilizar essas fixtures.
- **Verificação:** 31/31 testes Jest passando (reexecutado com `npx jest --globalSetup=""`). O build de produção do webpack e o `tsc` sem erros novos foram reportados pelo agente e não reexecutados.

### Pendências da Fase 4
- "Duplicar no editor" numa policy **específica de API** cria a cópia como policy **comum**, porque o dialog de criação específica não tem rota.
- "Duplicar no editor" e a validação no servidor só funcionam depois da Fase 3.
- As 20 chaves de i18n foram adicionadas à mão no `en.json`.
- Reverter o `package-lock.json` antes de commitar.

---

## Processos

- Agente da Fase 1: **encerrado**.
- Gateway local (PID 27316) e build Maven órfão (PID 24056): **encerrados**.
- Nenhum processo do projeto está rodando.

## Próximos passos sugeridos
1. Retomar a Fase 1 pelos passos acima; é o maior risco técnico restante.
2. Em seguida, Fases 2 e 3 em paralelo, depois de fixar os DTOs do contrato entre o Control Plane e o Gateway.
3. Fase 5 (painel de teste na UI) e Fase 6 (config, testes de integração e bump de versões com build completo das features).
