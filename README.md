# Examen de práctica · Economía

Examen autocorregible de 6 ejercicios (nivel terciario). Es una sola página estática: `index.html`.

## Contenidos
1. Economía positiva y normativa
2. Microeconomía y macroeconomía
3. Modelos y sistemas económicos
4. El problema económico: necesidades, recursos y bienes
5. Variables en la actividad minera (exógenas/endógenas, flujo/stock)
6. Variables nominales y reales

## Ajustes rápidos (dentro de `index.html`)
- `NOTA_APROBACION`: nota mínima para aprobar (por defecto 6).
- `MEZCLAR`: mezcla el orden de preguntas y opciones en cada intento.
- `EXAMEN`: banco de preguntas; cada pregunta tiene su respuesta correcta (`a`) y explicación (`exp`).

## Publicar en Vercel
1. Subir esta carpeta a un repositorio de GitHub.
2. En vercel.com → **Add New → Project** → importar el repositorio.
3. Framework Preset: **Other**. No hace falta comando de build ni configuración.
4. **Deploy**. Cada `git push` vuelve a publicar automáticamente.
