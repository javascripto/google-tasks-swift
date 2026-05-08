@/Users/yuri/.codex/RTK.md

# Google Tasks macOS

Use o `Makefile` como interface padrao de execucao do projeto. A maquina do Yuri tem `rtk` (Rust Token Killer) instalado, entao nela chame os comandos com `rtk` por fora. Se a maquina onde o projeto estiver sendo executado nao tiver `rtk`, use `make` puro.

## Comandos

- Maquina com `rtk`: `rtk make build`, `rtk make stop`, `rtk make run`.
- Maquina sem `rtk`: `make build`, `make stop`, `make run`.

## Regra de execucao

Sempre que o usuario pedir uma alteracao e for necessario executar o app, rode:

```bash
rtk make run
```

Se `rtk` nao existir na maquina atual, rode:

```bash
make run
```

Nao rode `swift run google-tasks` diretamente para iniciar o app durante alteracoes. Tambem nao coloque `rtk` dentro do `Makefile`; use `rtk make ...` no terminal apenas quando Rust Token Killer estiver instalado. O alvo `run` ja mata o processo anterior antes de abrir uma nova instancia.

Para validar o core sem abrir a UI:

```bash
rtk make selftest
```

Sem `rtk`:

```bash
make selftest
```
