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
