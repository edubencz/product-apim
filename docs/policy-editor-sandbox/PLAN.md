# Editor de Policy Synapse (.j2) com diagrama ao vivo e "Testar agora"

## Contexto

Hoje, em `/publisher/policies/create`, o usuário escreve o `.j2` (DSL de mediação do Synapse) fora da aplicação e só faz upload. Para validar, precisa anexar a policy a uma API, fazer deploy de uma revisão e chamá-la. O upload também não valida o `.j2`: a renderização com Jinjava e a checagem do XML só acontecem no deploy (`SynapsePolicyAggregator`).

Objetivo: escrever o fluxo dentro do Publisher, com um editor Monaco e um diagrama sincronizado, e executá-lo na hora num Synapse real do Gateway, com mocks opcionais para chamadas externas.

### Restrições encontradas
- O workspace é só **product-apim**, que empacota os artefatos. A UI vem do artefato `org.wso2.carbon.apimgt.ui:apim.ui.apps.portals` 9.3.194 e o backend do **carbon-apimgt** 9.33.176 (`api-control-plane/pom.xml:1285-1288`). O código-fonte dos dois não está aqui.
- O **control plane não tem Synapse**. Só tem Axis2/Axiom e `jinjava-2.7.6`. O Synapse (4.1.0-wso2v59) e o carbon-mediation existem apenas no perfil **gateway**.
- O CP hoje **não chama** os gateways; eles puxam artefatos e recebem eventos. A única referência que o CP tem é `[[apim.gateway.environment]] service_url/username/password`.
- O Gateway tem uma REST interna, `api#am#gateway#v2`, em CXF com basic auth: é o lugar natural para o sandbox.
- A UI já usa `@monaco-editor/react` 4.7.0, com `loader.config({monaco})` e `monaco-editor-webpack-plugin`. Não há biblioteca de diagrama.

### Decisões do usuário
1. Implementar nos repositórios upstream clonados, com integração nativa na tela.
2. O teste roda num **Synapse real no Gateway**.
3. O **código é a fonte da verdade**. O diagrama é gerado a partir do XML, e clicar num nó leva à linha correspondente. Há uma paleta de snippets.
4. `<call>`/`<send>` fazem **chamadas reais por padrão**, com **mocks opcionais por URL**.
5. O browser só fala com o **CP**. O CP faz proxy para o gateway escolhido.
6. **Sem allowlist de mediadores**, mas a feature fica atrás de uma flag (desligada por padrão) + escopo + timeouts.
7. Não haverá edição (PUT). A tela de visualização ganha **"Duplicar no editor"**.

---

## Arquitetura

```
Browser (Publisher UI)
  ├─ Monaco (.j2) ──parse local──► FlowDiagram (SVG)
  ├─ POST /operation-policies/render  (CP: Jinjava + normalize + XML parse)  ← sem gateway
  └─ POST /operation-policies/test    (CP) ──basic auth──► Gateway
                                               POST /api/am/gateway/v2/policy-sandbox/execute
                                               └─ API Synapse temporária em memória + chamada loopback
                                                  (trace markers, captura de estado/logs, mocks)
```

---

## Fase 0: Setup dos repositórios
- Clonar `wso2/carbon-apimgt` numa tag/commit equivalente a 9.33.176 e o repositório da UI. Provavelmente é `wso2/apim-apps`; confirmar com `grep -r apim.ui.apps.portals --include=pom.xml` qual repositório/tag gera a 9.3.194. Os dois ficam como irmãos de `wso2-product-apim` em `c:\workspace\`.
- Fazer build de SNAPSHOTs sem alterações e trocar as versões em `api-control-plane/pom.xml`, `gateway/pom.xml` e `all-in-one-apim/pom.xml` (mais o root, se houver). Manter `synapse.version` em v59. Em `~/.m2` só há a v67, então vai baixar a v59.
- **Verificar:** as distribuições acp e gateway sobem, e o `operation_policies.feature` (integration-v2) continua passando.

## Fase 1: Spikes no Gateway (riscos maiores primeiro)
Um recurso REST descartável para provar três coisas:
a) Adicionar e remover uma API Synapse em runtime (`APIFactory.createAPI` → `api.init(env)` → `synapseConfig.addAPI` / `removeAPI` + `destroy`) e chamá-la em loopback na porta passthrough.
b) Capturar logs via appender log4j2 com `ThreadContextMapFilter` (`apim.sandbox.runId`) sob pax-logging. Se não funcionar, usar reflexão em `LogMediator`.
c) Resolver um class mediator num novo pacote exportado de `org.wso2.carbon.apimgt.gateway`.
- **Verificar:** uma sequência escrita à mão com `respond`, `call` bloqueante e `call` não-bloqueante devolve logs e trace.

## Fase 2: Sandbox no Gateway (carbon-apimgt)
Novo pacote `org.wso2.carbon.apimgt.gateway.sandbox` em `components/apimgt/org.wso2.carbon.apimgt.gateway`, adicionado ao Export-Package:
- `PolicySandboxService`: orquestra a execução. Usa `Semaphore(max_concurrent_runs)`, aplica timeout e faz cleanup no `finally`.
- `SandboxApiBuilder`: monta a API `/__apim_policy_sandbox/{runId}`, recurso `/*`, todos os métodos.
  - inSequence = policy instrumentada + `SandboxCaptureMediator(end)` + `<respond/>`.
  - out/fault sequences fazem a captura e respondem. Na fault, respondem com JSON 500 + `ERROR_CODE/MESSAGE`.
  - Uma API de mocks em `/…/{runId}/mocks/m{i}` → `MockResponderMediator`.
- `SequenceInstrumenter`: insere `TraceMarkerMediator(runId,nodeId)` antes de cada mediador, seguindo o **contrato de nodeId** (abaixo).
- `MockEndpointRewriter`: reescreve `endpoint/http@uri-template` e `address@uri` que casam com mocks (GLOB/REGEX) para o loopback. `endpoint key=`, `To` dinâmico e `key-expression` viram warnings.
- `EndpointTimeoutInjector`: adiciona `<timeout>` aos endpoints inline que não têm.
- `SandboxCaptureMediator`: captura payload (JSON via `JsonUtil`, senão body), content type, `TRANSPORT_HEADERS`, `HTTP_SC`, propriedades Synapse e as propriedades axis2 relevantes, tudo truncado.
- `SandboxGuardHandler`: aceita só loopback + header `X-APIM-Sandbox-Token`.
- `SandboxLogAppender`, `SandboxRunRegistry` (com TTL) e `SandboxJanitor`, que remove APIs `__apim_policy_sandbox_*` com mais de 5 minutos.
- REST: `POST /policy-sandbox/execute` em `gateway-api.yaml` + `web.xml` (`jaxrs.serviceClasses`) + `PolicySandboxApiServiceImpl`. Recebe o XML **já renderizado**. Retorna 404 se `[apim.policy_sandbox] enable=false`. Exige admin.
- Semântica do resultado:
  - `<respond/>` na policy dá `respondedEarly=true`.
  - `<drop/>` dá `DROPPED`.
  - Estourar o tempo dá `TIMEOUT`.
  - Chamadas bloqueantes e não-bloqueantes funcionam nativamente.
  - Todas as chamadas externas aparecem em `outboundCalls`, com a flag `mocked`.
- Limites: `execution_timeout` 20s, `max_concurrent_runs` 4, body ≤ 1 MB, respostas/snapshots ≤ 64 KB, logs ≤ 500 linhas.
- **Verificar:** curl com basic auth enviando o sample `lean-auth-policy`:
  - com o token mockado em 401: trace passa por `…/else/…` e `respondedEarly=true`;
  - com mock 200: o payload original é restaurado e o header `Authorization` está presente;
  - nenhuma API sandbox fica deployada depois da execução.

### Contrato de nodeId (compartilhado entre Gateway e UI)
É o caminho de índices dos elementos filhos entre containers de mediadores, por exemplo `3`, `5/then/1`, `6/case[2]/0`, `6/default/0`.
Containers: raiz, `then`, `else`, `filter` sem then/else, `switch/case|default`, `sequence` inline (clone/iterate/foreach target), `throttle/onAccept|onReject`, `cache/onCacheHit`, `aggregate/onComplete`, `validate/on-fail`.
A contagem é feita **após a normalização** e com a mesma regra dos dois lados. Os dois lados terão testes unitários com as mesmas fixtures.

## Fase 3: Endpoints no Control Plane (carbon-apimgt)
`publisher-api.yaml` (publisher v1) + DTOs regenerados:
- `POST /operation-policies/render`
  - Request: `{policyDefinition, attributeValues{}}`.
  - Response: `{renderedSequence, normalized, errors[{line,column,message,severity}], warnings[], detectedVariables[], unknownMediators[]}`.
- `POST /operation-policies/test`
  - Request: `{policyDefinition, attributeValues, flow, sampleRequest{method,path,headers,body,contentType}, mocks[{urlPattern,matchType,method,status,headers,body,contentType,delayMs}], extraProperties{}, gatewayEnvironment}`.
  - Response: os campos do render + `execution{status, respondedEarly, durationMs, clientResponse, finalMessage, properties{synapse,axis2,transport}, logs[], trace[], outboundCalls[], fault}`.
- `GET /operation-policies/test/environments` e a flag `operationPolicyTestEnabled` em `SettingsDTO`.
- `GET /operation-policies/{id}/definition?gatewayType=Synapse` e o equivalente em `/apis/{apiId}/operation-policies/{id}/definition`. Devolvem texto puro para o "Duplicar no editor".
- Escopos reaproveitados: `apim:common_operation_policy_create|manage` e `apim:mediation_policy_create` (+ `apim:api_create` na página específica de API).

Implementação:
- `OperationPoliciesApiServiceImpl` e `ApisApiServiceImpl` ganham os novos métodos.
- Novo pacote `org.wso2.carbon.apimgt.impl.policy.sandbox`:
  - `OperationPolicyRenderer`: faz o render com Jinjava usando a mesma chamada do `SynapsePolicyAggregator` e coleta `renderForResult().getErrors()`. Depois envolve o resultado em `<sequence xmlns=synapse>` e faz `APIUtil.buildSecuredOMElement`, mapeando os erros para linha/coluna. Mediadores desconhecidos geram apenas warning, comparando com uma lista estática.
  - `SequenceNormalizer`: se a raiz for `<sequence>` (caso do arquivo do usuário), faz unwrap dos filhos, descarta o `name` e devolve `normalized=true` com um warning. Assim o teste reflete o que vai para o deploy, já que o aggregator envolve o conteúdo em outro `<sequence>`.
  - `GatewaySandboxClient`: busca o Environment via `APIUtil.getEnvironments`. A URL base é o `sandbox_url` (opcional) ou `service_url` com `/services/` trocado por `/api/am/gateway/v2`. Autentica com basic auth usando as credenciais do Environment e aplica o timeout `apim.policy_sandbox.timeout`.
- Configuração: bloco `<OperationPolicySandbox>` no `api-manager.xml.j2` (feature do carbon-apimgt) + parsing em `APIManagerConfiguration` + `APIConstants`.
- Testes unitários cobrem renderer, normalizer, derivação de URL e erros com linha.
- **Verificar:** curl em `/api/am/publisher/v4/operation-policies/render` e `/test` de ponta a ponta. Um usuário subscriber deve receber 401/403, e com a flag desligada a resposta deve ser 404.

## Fase 4: UI, editor e diagrama (repositório da UI, publisher)
Pasta compartilhada: `source/src/app/components/Apis/Details/Policies/PolicyForm/Editor/`. Serve tanto a página de policy comum quanto a específica de API.
- `PolicyEditorWorkspace.tsx`: dialog em tela cheia com Monaco à esquerda, FlowDiagram à direita (redimensionável) e TestPanel embaixo. No `SourceDetails` fica um Monaco compacto com um botão "Abrir editor".
- `PolicyCodeEditor.tsx`: Monaco `xml`, seguindo o padrão de `PolicyAttributes.tsx`.
  - Decorações para `{{ }}` e `{% %}`.
  - Autocomplete de tags e atributos de mediadores e de `{{atributo}}` do spec.
  - Markers vindos do parse local + `/render` com debounce de 600ms.
  - Quick fix "Remover `<sequence>` raiz".
  - API `revealLine` para o clique no diagrama.
- `MediatorPalette.tsx` + `snippets/mediatorSnippets.ts`: property, header, payloadFactory (json/text/xml), log, filter then/else, switch, call bloqueante com http endpoint, respond, enrich, script, drop.
- `templates/starterTemplates.ts`: add/remove header, transformação JSON, respond condicional e "Token exchange + auth", que é o padrão do exemplo do usuário já sem `<sequence>` raiz.
- `parsing/`:
  - `j2Mask.ts`: troca `{{…}}` e `{% %}` por placeholders de mesmo tamanho, preservando offsets.
  - `parseSynapseXml.ts`: usa `DOMParser` + varredura de posições e gera a árvore `FlowNode` seguindo o contrato de nodeId.
  - `detectVariables.ts`
- `diagram/FlowDiagram.tsx`, `layout.ts` e `mediatorCatalog.ts`:
  - **SVG feito à mão**, sem nova dependência. O grafo é série-paralelo, então basta um layout vertical recursivo com os ramos lado a lado.
  - Pan e zoom com CSS transform.
  - O resumo de cada nó mostra `source/regex`, URI ou `name=value`.
  - Overlay de trace: nós executados numerados, ramos não executados esmaecidos e marca "terminou aqui" no respond.
- Integração:
  - `SourceDetails.tsx` (~L254) ganha as abas **"Upload de arquivo" | "Escrever no editor"**. O estado (`synapseEditorContent`, `sourceMode`) fica em `CommonPolicies/CreatePolicy.tsx` e `Apis/Details/Policies/CreatePolicy.tsx`.
  - Ao salvar, o conteúdo vira `new File([content], \`${name}_v${version}.j2\`)` e segue pelo `addCommonOperationPolicy` ou `addOperationPolicy` que já existem.
  - A validação de `PolicyCreateForm.tsx` (L240-244) passa a aceitar conteúdo do editor.
  - Variáveis `{{x}}` que não estão em `policyAttributes` viram chips "Adicionar como atributo", que disparam a action do reducer.
  - `ViewPolicy.tsx` (comum e de API) ganha o botão "Duplicar no editor", que usa o GET `/definition` e faz `history.push('/policies/create', {base})`. O `CreatePolicy` pré-preenche a partir de `location.state`, com o sufixo `_copy` no nome.
- `data/api.js`: `renderOperationPolicy`, `testOperationPolicy`, `getPolicySandboxEnvironments`, `get(Common)OperationPolicyDefinition`.
- i18n: IDs `Apis.Details.Policies.PolicyForm.Editor.*` + `npm run i18n:en`.
- **Verificar:**
  - Jest para `parseSynapseXml` (nodeIds, usando as mesmas fixtures do Java) e para `layout`.
  - Manual: o diagrama atualiza ao digitar, o clique no nó vai para a linha, e uma policy criada pelo editor anexada a uma API funciona após o deploy.

## Fase 5: UI, painel de teste
- `test/TestPanel.tsx`:
  - `AttributeValuesForm` é derivado do `policyAttributes` do spec, com tipos e defaults.
  - `SampleRequestEditor` tem método, path, tabela de headers e body em Monaco.
  - Também inclui `MocksEditor`, um campo de extraProperties e o seletor de gateway.
- `TestResults.tsx` tem as abas: Resposta ao cliente | Mensagem final | Propriedades | Logs (clique leva ao nó) | Trace | Chamadas externas | XML renderizado.
- Hooks `usePolicyRender`/`usePolicyTest`. A aba Teste fica oculta se `operationPolicyTestEnabled=false`, mas render e validação estão sempre disponíveis.
- **Verificar:** o cenário completo do `lean-auth-policy` no browser, com o token mockado (200 e 401) e com chamada real.

## Fase 6: Fechamento no product-apim
- `default.json` de acp, gateway e all-in-one (`*/modules/distribution/product/src/main/resources/conf/default.json`):
  - `apim.policy_sandbox.enable=false`
  - `timeout=30000`
  - `execution_timeout=20000`
  - `max_concurrent_runs=4`
  - `max_log_lines=500`
- `deployment.toml` de cada perfil: exemplo comentado de `[apim.policy_sandbox]`, e nota recomendando um gateway environment dedicado e não-produtivo.
- integration-v2:
  - Novos `features/publisher/operation_policy_sandbox.feature`, `runners/block/PublisherOperationPolicySandboxRunner.java` e `OperationPolicySandboxSteps.java`, com uma variante de toml com a flag ligada.
  - Cenários:
    - normalização de `<sequence>`;
    - erro de XML com linha;
    - mock 401 que responde cedo;
    - mock 200 que restaura o payload;
    - flag desligada retorna 404;
    - subscriber recebe 401/403;
    - timeout via `delayMs`.
  - Seguir o padrão de `operation_policies.feature` / `PublisherOperationPoliciesRunner.java`.
  - Atualizar o `publisher-api.yaml` do cliente de testes (`all-in-one-apim/modules/integration/tests-common/clients/publisher/...`) só se os testes precisarem.

---

## Execução com agentes Sonnet
- Cada fase é delegada a um agente `general-purpose` com `model: "sonnet"`, recebendo no prompt a seção correspondente deste plano, o contrato de nodeId e os caminhos de referência. Uso `isolation: "worktree"` quando for no mesmo repositório.
- Ordem: 0 → 1 (se o spike falhar, paro e consulto o usuário) → 2 e 3 em paralelo, depois de fixados os DTOs do contrato gateway↔CP → 4 (pode começar junto com a 2/3, usando fixtures) → 5 → 6.
- Eu reviso cada entrega: diff, build, testes e os passos de "Verificar" de cada fase antes de seguir.
- Não faço commit nem push sem pedido explícito.

## Riscos e pontos em aberto
1. Captura de logs sob pax-logging (spike 1b).
2. Handlers globais e analytics do gateway atuando sobre a API temporária (conferir `synapse-handlers.xml`).
3. Qual role o `BasicAuthenticationInterceptor` da REST do gateway exige, e se as credenciais do Environment valem num gateway distribuído.
4. Environments criados pelo Admin portal (DB) não têm `service_url`. Só serão suportados os definidos em config ou com `sandbox_url`.
5. O sandbox não passa pelos handlers do APIM e não tem contexto de auth (`api.ut.*`). Para simular isso, o request aceita `extraProperties`.
6. **Segurança:** o sandbox aceita qualquer mediador (script, class) e faz chamadas reais a partir do gateway. Por isso a flag vem desligada por padrão, com escopos de publisher/admin e guarda loopback + token.
7. Detalhes de build ainda não testados: regeneração de DTOs swagger no carbon-apimgt, tag exata que corresponde a 9.33.176/9.3.194, e Synapse v59 vs v67.
