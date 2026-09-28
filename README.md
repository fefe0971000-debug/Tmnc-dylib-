# SatanabeCleanUI v5.4 — API Switcher

Base: v5.3 patch/project exporter.

## Novo: Conexão / API
- Perfis API A, API B e Custom.
- API A vem preenchida com `https://api-production-182c.up.railway.app`.
- API B e Custom ficam editáveis no flutuante.
- Liga/desliga o roteamento sem recompilar.
- Host original opcional para limitar quais requisições podem ser redirecionadas.
- Filtro de rotas por prefixo, separado por vírgula.
- Opção `Preservar rota da IPA`: troca somente scheme/host/porta e mantém path/query da requisição original.
- Botão `Testar API ativa`.
- Intercepta data/download/upload tasks do NSURLSession com request/URL.

## Nome genérico
A área foi chamada de **Conexão / API** e o componente interno de **Backend Router**, evitando nomes específicos de bypass.

## Importante sobre o dump enviado
O `texto.txt` enviado contém interfaces do framework `Calculate` (calculadora/conversão) e não expõe as classes do sistema local de key, endpoints HTTP ou URLSession do External. Por isso esta versão NÃO inventa hooks de classes que não aparecem no dump. O roteador funciona de forma genérica em NSURLSession e pode apontar as rotas compatíveis para API A/B/Custom.

## Segurança contra redirecionamento acidental
Deixe `Host original` preenchido quando souber o domínio original. Assim só requisições daquele host e das rotas permitidas são trocadas.
