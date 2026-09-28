# SatanabeCleanUI v5.3 — 3105 Project Exporter

Exportador compatível com dois fluxos locais:

- arquivos `.3105` reais;
- arquivos de cache que perderam a extensão, detectados pela assinatura `3105PATCH`;
- projetos já importados pelo 3105, detectados por `.3105-project.plist`.

No flutuante, use **Exportar patches instalados**. É possível marcar um ou vários itens.

Para um pacote 3105 real, os bytes são compartilhados sem alteração. Para um `PatchProject` já decodificado, a dylib preserva a pasta inteira do projeto em ZIP e acrescenta `PATCH_PATH.txt` com caminhos/metadados encontrados no manifesto.

Isso evita depender de Supabase/Railway: a detecção é feita no armazenamento local do app.
