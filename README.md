# SatanabeCleanUI v5.8 — API Logger

Build de diagnóstico passivo para iOS.

- Registra requisições HTTP/HTTPS observadas pelo stack Foundation.
- Guarda URL completa, método, headers seguros, status HTTP e tempo.
- Correlaciona tentativas de licença com a key encontrada no body/query/header.
- Marca `VALID` / `INVALID` quando a resposta fornece evidência suficiente.
- Adiciona **Compartilhar log** aos pop-ups enquanto o logger estiver ativo.
- Cada entrada em **Ver logs da API** tem **Compartilhar este log**.
- **Compartilhar todos os logs** envia o arquivo JSONL completo.
- **Mapear URLs do binário** procura URLs HTTP/HTTPS no executável e em Mach-O carregados.
- Não reescreve URL, não troca backend e não responde validação localmente.

Observação técnica: nenhum logger dentro de uma dylib pode prometer capturar tráfego feito fora dos stacks interceptados
(por exemplo, sockets/C libraries próprios ou tráfego criptografado por uma implementação privada). Para NSURLSession/URLProtocol
HTTP/HTTPS, esta build registra o tráfego observado sem modificar a resposta do servidor.
