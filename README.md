# SatanabeCleanUI v5

Pacote de personalização visual/UX para o próprio app iOS.

## Incluído
- Liquid Glass liga/desliga
- Intensidade do Glass
- Cor dos cards
- Cor de destaque/bordas
- Raio dos cards
- Espessura das bordas
- Vídeo original ou personalizado
- Seletor de vídeo pelo app Arquivos
- Vídeo em loop via AVPlayerLooper
- Botão flutuante arrastável com posição persistente
- Tamanho e opacidade do botão flutuante
- Feedback tátil opcional
- Cópia da configuração em JSON
- Restauração do visual original
- Watchdog leve para recriar somente o botão flutuante
- Correção de recursão em UIVisualEffectView herdada da v4.1

Não altera autenticação, keys, Supabase, patches, anti-cheat, DRM ou sandbox.

## Build
Use o workflow `.github/workflows/build.yml` no GitHub Actions em um runner macOS com Xcode, ou rode `make` em macOS com Xcode instalado.

## v5.1 — Exportador de patch/payload
No flutuante, em **Ferramentas de patch**, existe **Exportar .3105 / arquivo + caminho**.

Fluxo:
1. Escolha um `.3105` ou o arquivo/payload final.
2. Informe a pasta destino, por exemplo `com.dts.freefireth/Documents/contentecache/...`.
3. Confirme ou altere o nome final do arquivo.
4. O tweak gera `Satanabe-Patch-Export.zip` contendo a estrutura completa de pastas, o arquivo no destino informado e `PATCH_PATH.txt` com o caminho por escrito.

A função exporta arquivos que o usuário seleciona/que o app tem permissão para acessar. Ela não tenta atravessar o sandbox de outros aplicativos.

## v5.1.1 build fix
Corrige o erro de compilação na rotina de exportação substituindo `typeof(self)` por tipos Objective-C explícitos e evitando o ciclo de retenção entre o alerta e o bloco da ação.
