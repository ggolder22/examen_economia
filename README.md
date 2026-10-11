# Examen de Economía

| Página | URL | Para quién |
|---|---|---|
| Práctica autocorregible | `/` | Alumnos (estudiar) |
| Examen real | `/examen/` | Alumnos (el día del examen) |
| Panel docente | `/admin/` | Docente |

## Cómo funciona el examen real
- El alumno ingresa con **DNI, apellido y nombre**. Queda registrado y, en ese dispositivo, la próxima vez entra solo.
  Si cambia de teléfono, vuelve a escribir los mismos datos y sigue donde estaba.
- Mientras la docente no habilite el examen, el alumno queda **en espera**; cuando lo habilita, empieza solo.
- Cada respuesta se guarda **al instante** en Supabase y también en el teléfono. Si se corta internet, se tilda o se cierra
  la página, no se pierde nada: al volver a entrar continúa con el tiempo que le queda.
- El tiempo lo controla el servidor (no el reloj del celular). Al terminar, el examen se entrega solo.
- Cada alumno puede rendir **una sola vez**. Las preguntas y opciones aparecen en distinto orden para cada alumno.
- La corrección se hace en el servidor: las respuestas correctas nunca llegan al teléfono del alumno.
- Todo queda en la tabla `registro`: ingresos, cada respuesta, entregas y acciones de la docente.

## Panel docente (`/admin/`)
- **Examen**: definir el tiempo disponible y el botón **Habilitar inicio del examen**; agregar minutos; finalizar.
- **Alumnos y notas**: estado en vivo de cada alumno, nota, detalle de respuestas, registro de actividad,
  permitir un nuevo intento, eliminar, descargar planilla CSV (abre en Excel).
- **Preguntas**: ver, editar, agregar y eliminar preguntas (no se puede durante el examen).
- **Configuración**: título, nota de aprobación, mostrar o no la nota al alumno al entregar, y botones para
  borrar todo después de una prueba.

## Puesta en marcha (una sola vez)

### 1. Supabase
1. Crear un proyecto en [supabase.com](https://supabase.com) (el plan gratuito alcanza para 50 alumnos simultáneos).
2. **SQL Editor → New query**: pegar todo `supabase/schema.sql` y presionar **Run**. Crea las tablas, funciones y las 10 preguntas.
3. **Authentication → Users → Add user → Create new user**: email y contraseña de la docente (marcar *Auto Confirm User*).
4. En el SQL Editor, habilitarla como docente:
   ```sql
   insert into public.admins (user_id, email)
   select id, email from auth.users where email = 'EMAIL_DE_LA_DOCENTE';
   ```
5. **Authentication → Sign In / Providers**: desactivar *Allow new users to sign up* (nadie más puede crear cuentas).
6. **Project Settings → API**: copiar la *Project URL* y la clave *anon* (o *publishable*) en `assets/config.js`.

### 2. Vercel
Subir los cambios a GitHub; Vercel publica solo. No requiere configuración.

## Antes del examen
- Hacer una **prueba completa** (habilitar con 2–3 minutos, entrar con un DNI de prueba, entregar) y luego en
  **Configuración → Borrar alumnos y exámenes**.
- Supabase gratuito **pausa el proyecto tras 7 días sin uso**: entrar al panel el día anterior para mantenerlo activo.
- Los alumnos pueden registrarse antes de que empiece; conviene pedirles que entren unos minutos antes.
