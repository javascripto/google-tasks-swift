# Google Tasks macOS

Cliente macOS nativo para Google Tasks, feito em SwiftUI, com inicializacao rapida, cache local, OAuth desktop e sincronizacao pela Google Tasks REST API v1.

## Recursos

- Login/logout com OAuth desktop e tokens no Keychain.
- Cache local para abrir a interface antes da rede responder.
- Sincronizacao ao abrir, ao voltar ao foco e por polling enquanto o app esta ativo.
- Listas: criar, renomear, excluir com confirmacao, ocultar localmente e reordenar localmente.
- Tarefas: criar, editar titulo inline, editar notas/data, concluir/reabrir e excluir com confirmacao.
- Organizacao: buscar tarefas na lista atual, criar subtarefas, reordenar via `tasks.move` e mover tarefa para outra lista.
- Filtros: pendentes, todas e concluidas.
- App no Dock, menu bar ou ambos, com lista compacta de pendentes na menu bar.
- Icone colorido para o app e icone monocromatico/template para a menu bar.

## Requisitos

- macOS com Swift 6.3 ou compativel.
- OAuth Client do Google Cloud do tipo **Desktop app**.
- Google Tasks API ativada no projeto Google Cloud.

## Configuracao local

Crie `.env.local` na raiz do repo:

```bash
GOOGLE_TASKS_CLIENT_ID=seu-client-id.apps.googleusercontent.com
GOOGLE_TASKS_CLIENT_SECRET=seu-client-secret-local
```

`.env.local` e `client_secret*.json` sao ignorados pelo git. O app tambem inclui `.env.example` com placeholders.

## Comandos

Nesta maquina, use `rtk` por fora dos comandos:

```bash
rtk make build
rtk make selftest
rtk make run
rtk make stop
rtk make clean
```

Em maquinas sem `rtk`, use `make` puro:

```bash
make build
make selftest
make run
make stop
```

O alvo `run` sempre chama `stop`, empacota `dist/GoogleTasks.app`, registra o bundle no LaunchServices e abre o app.

## Estrutura

- `Sources/GoogleTasksCore`: modelos, cache e cliente REST da API publica.
- `Sources/google-tasks`: app SwiftUI, OAuth, Keychain, menu bar e estado da UI.
- `Sources/google-tasks-icon`: gerador SwiftUI do icone `.icns`.
- `Sources/google-tasks-selftest`: validacao executavel sem depender de XCTest.
- `.codex/environments/environment.toml`: actions do Codex.

## Validacao

```bash
rtk make build
rtk make selftest
```

O selftest cobre parsing dos modelos, requests paginados, montagem de `tasks.move` e round-trip do cache em disco.

## Notas

A API publica do Google Tasks nao expoe estrela/repeticao como campos gravaveis. Essas funcionalidades nao estao implementadas para evitar dependencia de endpoints privados do Google Tasks Web.
