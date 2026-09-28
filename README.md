# SatanabeCleanUI v5.8.1 — API Logger build fix

Correções desta revisão:
- `__attribute__((constructor))` voltou a ficar imediatamente antes de `SCUIStart`.
- Removido o bloco recursivo `showOne`, eliminando a retenção/captura problemática mostrada no build.
- Navegação de logs agora usa método Objective-C normal: Anterior / Próximo / Compartilhar este log.
- Scanner de URLs foi simplificado para evitar callback recursivo/desnecessário.
- Mantém o comportamento de diagnóstico: logger, correlação key/URL/VALID/INVALID e compartilhamento.
- Não ativa troca de backend nem validação local.
