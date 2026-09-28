# SatanabeCleanUI v5.2 — exportador local .3105

No flutuante, em **Ferramentas de patch**, use **Exportar patches .3105 da IPA**.

A dylib procura arquivos `.3105` já existentes localmente no bundle da IPA e no sandbox do Satanabe External (Documents, Library e tmp). Ela abre uma lista com seleção múltipla. Marque um ou vários patches e toque em **Exportar** para abrir o compartilhamento nativo do iOS e escolher Arquivos, AirDrop, WhatsApp etc.

A opção **Exportar arquivo manualmente** foi mantida como fallback.

Importante: um item que exista apenas no catálogo remoto do Supabase, mas que nunca tenha sido baixado e não exista localmente, não pode ser exportado como arquivo pela dylib até existir no dispositivo.

## Build
Coloque `build.yml` em `.github/workflows/build.yml`, mantendo `Source/SatanabeCleanUI.mm` e `Makefile` na raiz conforme a estrutura deste ZIP. Rode o workflow no GitHub Actions.
