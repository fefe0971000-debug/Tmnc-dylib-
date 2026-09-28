# SatanabeCleanUI v5.5

## Novo
- Toggle **Bypass local (teste)** no flutuante.
- Intercepta somente `/api/license/validate`.
- Resposta local usa os campos identificados no dump principal do 3105.
- API A / API B / Custom continuam disponíveis.
- Filtro padrão inclui licença + patches.
- Workflow usa `macos-14`.

## GitHub
Coloque:
- `Makefile` na raiz.
- `Source/SatanabeCleanUI.mm`.
- `.github/workflows/build.yml`.

Depois rode Actions > Build SatanabeCleanUI v5.5 > Run workflow.
