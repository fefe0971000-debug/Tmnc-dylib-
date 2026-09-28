# SatanabeCleanUI v5.8.2 — API Logger

Correção específica do erro de compilação mostrado no GitHub Actions:

- removidos `__weak typeof(self)` e `__strong typeof(weakSelf)` do navegador de logs;
- os handlers agora chamam `self` diretamente;
- mantido o `constructor` imediatamente antes de `SCUIStart`;
- mantidos URL logger, correlação key + URL + VALID/INVALID;
- mantido Compartilhar este log, Compartilhar todos e compartilhamento em pop-ups;
- build continua somente diagnóstico, sem reescrever a API.

Estrutura pronta para GitHub Actions.
