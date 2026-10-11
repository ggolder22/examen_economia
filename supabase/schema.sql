-- =====================================================================
--  EXAMEN DE ECONOMÍA · Esquema de base de datos para Supabase
--  Ejecutar COMPLETO en: Supabase → SQL Editor → New query → Run
--
--  Seguridad: todas las tablas tienen RLS activado y SIN políticas,
--  por lo que nadie puede leerlas ni escribirlas directamente.
--  Todo el acceso se hace mediante funciones (RPC) que validan:
--    - alumnos: identificados por un token que se obtiene con DNI + apellido
--    - docente: usuario de Supabase Auth registrado en la tabla "admins"
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABLAS
-- ---------------------------------------------------------------------
create table if not exists public.config (
  id                int primary key default 1 check (id = 1),
  titulo            text    not null default 'Examen de Economía',
  duracion_min      int     not null default 40,
  inicio            timestamptz,
  fin               timestamptz,
  mostrar_resultado boolean not null default true,
  nota_aprobacion   numeric not null default 6
);
insert into public.config (id) values (1) on conflict do nothing;

create table if not exists public.preguntas (
  id          serial primary key,
  orden       int   not null default 0,
  enunciado   text  not null,
  opciones    jsonb not null,          -- array de textos
  correcta    int   not null,          -- índice (desde 0) de la opción correcta
  explicacion text
);

create table if not exists public.alumnos (
  dni           text primary key,
  apellido      text not null,
  nombre        text not null,
  token         uuid not null default gen_random_uuid() unique,
  creado        timestamptz not null default now(),
  ultimo_acceso timestamptz
);

create table if not exists public.intentos (
  dni          text primary key references public.alumnos(dni) on delete cascade,
  iniciado     timestamptz not null default now(),
  respuestas   jsonb not null default '{}'::jsonb,   -- { "id_pregunta": indice_opcion }
  actualizado  timestamptz,
  entregado    timestamptz,
  entrega_auto boolean not null default false,
  aciertos     int,
  total        int,
  nota         numeric,
  detalle      jsonb                                 -- copia de preguntas + respuestas al corregir
);

create table if not exists public.admins (
  user_id uuid primary key,
  email   text
);

-- Registro de todo lo que ocurre (ingresos, respuestas, entregas, acciones de la docente)
create table if not exists public.registro (
  id     bigserial primary key,
  ts     timestamptz not null default now(),
  dni    text,
  evento text not null,
  datos  jsonb
);
create index if not exists registro_dni_idx on public.registro (dni, ts desc);

alter table public.config    enable row level security;
alter table public.preguntas enable row level security;
alter table public.alumnos   enable row level security;
alter table public.intentos  enable row level security;
alter table public.admins    enable row level security;
alter table public.registro  enable row level security;

revoke all on public.config, public.preguntas, public.alumnos, public.intentos,
              public.admins, public.registro from anon, authenticated;

-- ---------------------------------------------------------------------
-- FUNCIONES INTERNAS
-- ---------------------------------------------------------------------
-- Margen después del fin para recibir las últimas respuestas (conexiones lentas)
create or replace function public._gracia() returns interval
language sql immutable as $$ select interval '60 seconds' $$;

create or replace function public._norm(t text) returns text
language sql immutable as $$
  select regexp_replace(
           lower(translate(trim(coalesce(t, '')), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')),
           '\s+', ' ', 'g')
$$;

create or replace function public._log(p_dni text, p_evento text, p_datos jsonb)
returns void language sql security definer set search_path = public as $$
  insert into registro (dni, evento, datos) values (p_dni, p_evento, p_datos);
$$;

create or replace function public._es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

create or replace function public._estado() returns text
language sql stable security definer set search_path = public as $$
  select case
           when inicio is null then 'no_iniciado'
           when now() < fin    then 'en_curso'
           else 'finalizado'
         end
  from config where id = 1;
$$;

-- ¿Se pueden recibir respuestas en este momento?
create or replace function public._ventana_abierta() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(inicio is not null and now() <= fin + _gracia(), false)
  from config where id = 1;
$$;

-- Guarda las respuestas válidas y registra solo las que cambiaron
create or replace function public._merge(p_dni text, p_resp jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actual  jsonb;
  v_cambios jsonb := '{}'::jsonb;
  k text; v jsonb; n int; num numeric;
begin
  if p_resp is null or jsonb_typeof(p_resp) <> 'object' then return; end if;

  select respuestas into v_actual from intentos
   where dni = p_dni and entregado is null for update;
  if not found then return; end if;

  for k, v in select * from jsonb_each(p_resp) loop
    n := null;
    if jsonb_typeof(v) = 'number' then
      num := (v #>> '{}')::numeric;
      select jsonb_array_length(opciones) into n from preguntas where id::text = k;
      if n is not null and num = trunc(num) and num between 0 and n - 1
         and (v_actual -> k) is distinct from to_jsonb(num::int) then
        v_cambios := v_cambios || jsonb_build_object(k, num::int);
      end if;
    end if;
  end loop;

  if v_cambios <> '{}'::jsonb then
    update intentos set respuestas = respuestas || v_cambios, actualizado = now()
     where dni = p_dni;
    perform _log(p_dni, 'respuesta', v_cambios);
  end if;
end $$;

-- Corrige y cierra el intento de un alumno
create or replace function public._calificar(p_dni text, p_auto boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_resp jsonb; v_total int := 0; v_ok int := 0;
  v_det jsonb := '[]'::jsonb; r record; v_elegida int; v_nota numeric;
begin
  select respuestas into v_resp from intentos
   where dni = p_dni and entregado is null for update;
  if not found then return; end if;

  for r in select * from preguntas order by orden, id loop
    v_total := v_total + 1;
    v_elegida := (v_resp ->> r.id::text)::int;
    if v_elegida is not distinct from r.correcta then v_ok := v_ok + 1; end if;
    v_det := v_det || jsonb_build_array(jsonb_build_object(
      'id', r.id, 'enunciado', r.enunciado, 'opciones', r.opciones,
      'correcta', r.correcta, 'elegida', v_elegida,
      'ok', v_elegida is not distinct from r.correcta,
      'explicacion', r.explicacion));
  end loop;

  v_nota := case when v_total = 0 then 1
                 else greatest(1, round(v_ok * 10.0 / v_total, 1)) end;

  update intentos
     set entregado = now(), entrega_auto = p_auto,
         aciertos = v_ok, total = v_total, nota = v_nota, detalle = v_det
   where dni = p_dni;

  perform _log(p_dni, case when p_auto then 'entrega_automatica' else 'entrega' end,
               jsonb_build_object('aciertos', v_ok, 'total', v_total, 'nota', v_nota));
end $$;

-- Cierra los intentos que quedaron abiertos cuando terminó el tiempo
create or replace function public._cerrar_vencidos()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if exists (select 1 from config where id = 1 and fin is not null and now() > fin + _gracia())
     and exists (select 1 from intentos where entregado is null) then
    perform pg_advisory_xact_lock(424242);   -- un solo proceso cierra a la vez
    for r in select dni from intentos where entregado is null order by dni loop
      perform _calificar(r.dni, true);
    end loop;
  end if;
end $$;

create or replace function public._resultado(p_dni text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when c.mostrar_resultado then
           jsonb_build_object('visible', true, 'aciertos', i.aciertos, 'total', i.total,
                              'nota', i.nota, 'aprobado', i.nota >= c.nota_aprobacion,
                              'entregado', i.entregado, 'auto', i.entrega_auto,
                              'detalle', i.detalle)
         else
           jsonb_build_object('visible', false, 'entregado', i.entregado, 'auto', i.entrega_auto)
         end
  from intentos i, config c
  where i.dni = p_dni and c.id = 1 and i.entregado is not null;
$$;

-- ---------------------------------------------------------------------
-- FUNCIONES PARA ALUMNOS
-- ---------------------------------------------------------------------
create or replace function public.alumno_ingresar(p_dni text, p_apellido text, p_nombre text,
                                                  p_dispositivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_dni text := regexp_replace(coalesce(p_dni, ''), '\D', '', 'g');
  a alumnos;
begin
  if length(v_dni) < 7 or length(v_dni) > 9 then
    raise exception 'El DNI no es válido. Escribilo sin puntos.';
  end if;
  if _norm(p_apellido) = '' or _norm(p_nombre) = '' then
    raise exception 'Completá apellido y nombre.';
  end if;

  select * into a from alumnos where dni = v_dni;
  if not found then
    insert into alumnos (dni, apellido, nombre)
    values (v_dni, initcap(trim(p_apellido)), initcap(trim(p_nombre)))
    on conflict (dni) do nothing;
    select * into a from alumnos where dni = v_dni;
    perform _log(v_dni, 'registro', jsonb_build_object('apellido', a.apellido, 'nombre', a.nombre,
                                                       'dispositivo', p_dispositivo));
  elsif _norm(a.apellido) <> _norm(p_apellido) then
    raise exception 'Ese DNI ya está registrado con otro apellido. Avisale a la docente.';
  else
    perform _log(v_dni, 'ingreso', jsonb_build_object('dispositivo', p_dispositivo));
  end if;

  update alumnos set ultimo_acceso = now() where dni = v_dni;
  return jsonb_build_object('token', a.token, 'dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre);
end $$;

create or replace function public.alumno_estado(p_token uuid, p_respuestas jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a alumnos; c config; i intentos; v_estado text; v_tiene boolean; v_preg jsonb;
begin
  select * into a from alumnos where token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  update alumnos set ultimo_acceso = now() where dni = a.dni;

  perform _cerrar_vencidos();
  select * into c from config where id = 1;
  v_estado := _estado();

  select * into i from intentos where dni = a.dni;
  v_tiene := found;

  if not v_tiene and v_estado = 'en_curso' then
    insert into intentos (dni) values (a.dni) on conflict (dni) do nothing;
    if found then perform _log(a.dni, 'inicio_examen', null); end if;
    select * into i from intentos where dni = a.dni;
    v_tiene := true;
  end if;

  if v_tiene and i.entregado is null then
    if p_respuestas is not null and _ventana_abierta() then
      perform _merge(a.dni, p_respuestas);
    end if;
    if v_estado = 'finalizado' then
      perform _calificar(a.dni, true);
    end if;
    select * into i from intentos where dni = a.dni;
  end if;

  if v_tiene and i.entregado is null and v_estado = 'en_curso' then
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'enunciado', enunciado, 'opciones', opciones)
                              order by orden, id), '[]'::jsonb)
      into v_preg from preguntas;
  end if;

  return jsonb_build_object(
    'ahora', now(), 'estado', v_estado, 'titulo', c.titulo, 'inicio', c.inicio, 'fin', c.fin,
    'alumno', jsonb_build_object('dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre),
    'en_examen', coalesce(v_tiene and i.entregado is null and v_estado = 'en_curso', false),
    'respuestas', case when v_tiene then i.respuestas end,
    'preguntas', v_preg,
    'resultado', case when v_tiene and i.entregado is not null then _resultado(a.dni) end
  );
end $$;

create or replace function public.alumno_guardar(p_token uuid, p_respuestas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a alumnos;
begin
  select * into a from alumnos where token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  if not _ventana_abierta()
     or not exists (select 1 from intentos where dni = a.dni and entregado is null) then
    raise exception 'EXAMEN_CERRADO';
  end if;
  perform _merge(a.dni, p_respuestas);
  update alumnos set ultimo_acceso = now() where dni = a.dni;
  return jsonb_build_object('ok', true, 'ahora', now(), 'fin', (select fin from config where id = 1));
end $$;

create or replace function public.alumno_entregar(p_token uuid, p_respuestas jsonb, p_auto boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a alumnos; v_abierta boolean;
begin
  select * into a from alumnos where token = p_token;
  if not found then raise exception 'SESION_INVALIDA'; end if;
  if exists (select 1 from intentos where dni = a.dni and entregado is null) then
    v_abierta := _ventana_abierta();
    if v_abierta then perform _merge(a.dni, p_respuestas); end if;
    perform _calificar(a.dni, coalesce(p_auto, false) or not v_abierta);
  end if;
  return alumno_estado(p_token, null);
end $$;

-- ---------------------------------------------------------------------
-- FUNCIONES PARA LA DOCENTE
-- ---------------------------------------------------------------------
create or replace function public._exigir_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not _es_admin() then raise exception 'NO_AUTORIZADO'; end if;
end $$;

create or replace function public.admin_estado()
returns jsonb language plpgsql security definer set search_path = public as $$
declare c config; v_alumnos jsonb; v_preg jsonb;
begin
  perform _exigir_admin();
  perform _cerrar_vencidos();
  select * into c from config where id = 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre,
           'creado', a.creado, 'ultimo_acceso', a.ultimo_acceso,
           'tiene_intento', i.dni is not null, 'iniciado', i.iniciado,
           'respondidas', (select count(*) from jsonb_object_keys(coalesce(i.respuestas, '{}'::jsonb))),
           'entregado', i.entregado, 'entrega_auto', i.entrega_auto,
           'aciertos', i.aciertos, 'total', i.total, 'nota', i.nota)
         order by a.apellido, a.nombre), '[]'::jsonb)
    into v_alumnos
    from alumnos a left join intentos i on i.dni = a.dni;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.orden, p.id), '[]'::jsonb)
    into v_preg from preguntas p;

  return jsonb_build_object('ahora', now(), 'estado', _estado(), 'config', to_jsonb(c),
                            'alumnos', v_alumnos, 'preguntas', v_preg);
end $$;

create or replace function public.admin_alumno(p_dni text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  return jsonb_build_object(
    'alumno',   (select to_jsonb(a) - 'token' from alumnos a where dni = p_dni),
    'intento',  (select to_jsonb(i) from intentos i where dni = p_dni),
    'registro', (select coalesce(jsonb_agg(to_jsonb(r) order by r.ts desc), '[]'::jsonb)
                   from (select ts, evento, datos from registro where dni = p_dni
                         order by ts desc limit 300) r));
end $$;

create or replace function public.admin_iniciar(p_minutos int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if p_minutos is null or p_minutos < 1 or p_minutos > 600 then
    raise exception 'Indicá una duración entre 1 y 600 minutos.';
  end if;
  if _estado() = 'en_curso' then raise exception 'El examen ya está en curso.'; end if;
  if not exists (select 1 from preguntas) then raise exception 'No hay preguntas cargadas.'; end if;
  update config set inicio = now(), fin = now() + make_interval(mins => p_minutos),
                    duracion_min = p_minutos where id = 1;
  perform _log(null, 'docente_inicia_examen', jsonb_build_object('minutos', p_minutos));
end $$;

create or replace function public.admin_extender(p_minutos int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if _estado() <> 'en_curso' then raise exception 'El examen no está en curso.'; end if;
  update config set fin = fin + make_interval(mins => p_minutos) where id = 1;
  perform _log(null, 'docente_extiende_tiempo', jsonb_build_object('minutos', p_minutos));
end $$;

create or replace function public.admin_finalizar()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if _estado() <> 'en_curso' then raise exception 'El examen no está en curso.'; end if;
  update config set fin = now() where id = 1;
  perform _log(null, 'docente_finaliza_examen', null);
end $$;

create or replace function public.admin_permitir_nuevo_intento(p_dni text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  perform _log(p_dni, 'docente_borra_intento',
               (select to_jsonb(i) from intentos i where dni = p_dni));
  delete from intentos where dni = p_dni;
end $$;

create or replace function public.admin_eliminar_alumno(p_dni text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  perform _log(p_dni, 'docente_elimina_alumno',
               (select to_jsonb(a) - 'token' from alumnos a where dni = p_dni));
  delete from alumnos where dni = p_dni;
end $$;

create or replace function public.admin_guardar_pregunta(p_id int, p_orden int, p_enunciado text,
                                                         p_opciones jsonb, p_correcta int,
                                                         p_explicacion text)
returns int language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  perform _exigir_admin();
  if _estado() = 'en_curso' then
    raise exception 'No se pueden modificar preguntas mientras el examen está en curso.';
  end if;
  if coalesce(trim(p_enunciado), '') = '' then raise exception 'Falta el enunciado.'; end if;
  if jsonb_typeof(p_opciones) <> 'array' or jsonb_array_length(p_opciones) < 2 then
    raise exception 'La pregunta necesita al menos 2 opciones.';
  end if;
  if p_correcta is null or p_correcta < 0 or p_correcta >= jsonb_array_length(p_opciones) then
    raise exception 'Marcá cuál es la opción correcta.';
  end if;

  if p_id is null then
    insert into preguntas (orden, enunciado, opciones, correcta, explicacion)
    values (coalesce(p_orden, 0), trim(p_enunciado), p_opciones, p_correcta, p_explicacion)
    returning id into v_id;
  else
    update preguntas set orden = coalesce(p_orden, orden), enunciado = trim(p_enunciado),
           opciones = p_opciones, correcta = p_correcta, explicacion = p_explicacion
     where id = p_id returning id into v_id;
  end if;
  perform _log(null, 'docente_guarda_pregunta', jsonb_build_object('id', v_id));
  return v_id;
end $$;

create or replace function public.admin_eliminar_pregunta(p_id int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  if _estado() = 'en_curso' then
    raise exception 'No se pueden modificar preguntas mientras el examen está en curso.';
  end if;
  perform _log(null, 'docente_elimina_pregunta', (select to_jsonb(p) from preguntas p where id = p_id));
  delete from preguntas where id = p_id;
end $$;

create or replace function public.admin_config(p_titulo text, p_duracion int,
                                               p_mostrar boolean, p_nota_aprobacion numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  update config set titulo = coalesce(nullif(trim(p_titulo), ''), titulo),
                    duracion_min = coalesce(p_duracion, duracion_min),
                    mostrar_resultado = coalesce(p_mostrar, mostrar_resultado),
                    nota_aprobacion = coalesce(p_nota_aprobacion, nota_aprobacion)
   where id = 1;
  perform _log(null, 'docente_configura',
               jsonb_build_object('titulo', p_titulo, 'duracion', p_duracion,
                                  'mostrar', p_mostrar, 'nota_aprobacion', p_nota_aprobacion));
end $$;

-- Deja el examen como nuevo (para después de una prueba). El registro NO se borra.
create or replace function public.admin_reiniciar(p_borrar_alumnos boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _exigir_admin();
  delete from intentos where dni is not null;
  if p_borrar_alumnos then delete from alumnos where dni is not null; end if;
  update config set inicio = null, fin = null where id = 1;
  perform _log(null, 'docente_reinicia_examen', jsonb_build_object('borra_alumnos', p_borrar_alumnos));
end $$;

-- ---------------------------------------------------------------------
-- PERMISOS
-- ---------------------------------------------------------------------
revoke execute on function
  public._gracia(), public._norm(text), public._log(text, text, jsonb), public._es_admin(),
  public._estado(), public._ventana_abierta(), public._merge(text, jsonb),
  public._calificar(text, boolean), public._cerrar_vencidos(), public._resultado(text),
  public._exigir_admin()
from public, anon, authenticated;

revoke execute on function
  public.admin_estado(), public.admin_alumno(text), public.admin_iniciar(int),
  public.admin_extender(int), public.admin_finalizar(), public.admin_permitir_nuevo_intento(text),
  public.admin_eliminar_alumno(text), public.admin_guardar_pregunta(int, int, text, jsonb, int, text),
  public.admin_eliminar_pregunta(int), public.admin_config(text, int, boolean, numeric),
  public.admin_reiniciar(boolean)
from public, anon;

grant execute on function
  public.admin_estado(), public.admin_alumno(text), public.admin_iniciar(int),
  public.admin_extender(int), public.admin_finalizar(), public.admin_permitir_nuevo_intento(text),
  public.admin_eliminar_alumno(text), public.admin_guardar_pregunta(int, int, text, jsonb, int, text),
  public.admin_eliminar_pregunta(int), public.admin_config(text, int, boolean, numeric),
  public.admin_reiniciar(boolean)
to authenticated;

grant execute on function
  public.alumno_ingresar(text, text, text, text), public.alumno_estado(uuid, jsonb),
  public.alumno_guardar(uuid, jsonb), public.alumno_entregar(uuid, jsonb, boolean)
to anon, authenticated;

-- ---------------------------------------------------------------------
-- PREGUNTAS INICIALES (solo se cargan si la tabla está vacía)
-- ---------------------------------------------------------------------
insert into public.preguntas (orden, enunciado, opciones, correcta, explicacion)
select * from (values
  (1, '¿Cuál de los siguientes enunciados corresponde a la economía normativa?',
   '["La tasa de interés debería bajar para impulsar la producción nacional.", "Cuando baja el precio de un producto, los consumidores compran más de ese producto.", "La inflación del último año fue del 30%.", "Si aumenta la oferta de trabajo, el salario de equilibrio tiende a bajar."]'::jsonb,
   0, 'La economía normativa expresa juicios de valor sobre lo que DEBERÍA SER. Las demás opciones describen hechos o relaciones comprobables (economía positiva).'),
  (2, '¿Cuál de los siguientes temas es estudiado por la macroeconomía?',
   '["El precio del pan en una panadería del barrio.", "La inflación y el nivel de desempleo de un país.", "La decisión de una familia sobre cuánto ahorrar.", "La cantidad de trabajadores que contrata una empresa."]'::jsonb,
   1, 'La macroeconomía estudia variables agregadas de toda la economía: empleo, inflación, producto total, balanza comercial.'),
  (3, 'El problema económico fundamental es:',
   '["La falta de dinero de las personas.", "La falta de tecnología para producir.", "La escasez: necesidades ilimitadas frente a recursos limitados.", "El exceso de producción de las empresas."]'::jsonb,
   2, 'El problema económico es la escasez: hay que satisfacer necesidades crecientes e ilimitadas con recursos limitados, por eso hay que elegir.'),
  (4, '¿Cuál de los siguientes es un bien libre?',
   '["El agua potable que llega por red.", "El petróleo.", "El servicio de energía eléctrica.", "La luz del sol."]'::jsonb,
   3, 'Los bienes libres los provee la naturaleza en forma abundante, no tienen dueño ni precio. Los demás requieren trabajo y recursos, y tienen precio.'),
  (5, 'Las maquinarias, herramientas y vehículos de una empresa minera son:',
   '["Recursos de capital.", "Necesidades.", "Bienes libres.", "Recursos naturales."]'::jsonb,
   0, 'Son elementos que se utilizan para producir otros bienes: recursos (factores productivos) de capital.'),
  (6, '¿Qué caracteriza a una economía mixta?',
   '["La propiedad pública de todos los recursos y la planificación centralizada.", "Combina sector privado y sector público; el Estado corrige las fallas del mercado con impuestos y subvenciones.", "La propiedad privada sin ninguna intervención del Estado.", "El reparto igualitario de la riqueza decidido por el Estado."]'::jsonb,
   1, 'La economía mixta combina el sector privado y el público: la oferta y la demanda definen el mercado y el Estado cumple un rol corrector. Es el sistema más utilizado.'),
  (7, 'En el modelo de oferta y demanda de trabajo de programadores, si aumenta repentinamente la cantidad de profesionales calificados, el salario de equilibrio:',
   '["Tiende a subir, porque aumenta la demanda de trabajo.", "No cambia, porque el salario no depende de la oferta.", "Tiende a bajar, porque aumenta la oferta de trabajo.", "Desaparece, porque el mercado deja de funcionar."]'::jsonb,
   2, 'La oferta de trabajo depende de la cantidad de trabajadores calificados. Con más oferta y la misma demanda, el salario de equilibrio tiende a bajar.'),
  (8, 'Para una empresa minera, ¿cuál de las siguientes variables es exógena?',
   '["Las toneladas de mineral producidas.", "El precio internacional del mineral.", "Los ingresos por ventas de la empresa.", "Las ganancias de la empresa."]'::jsonb,
   1, 'El precio internacional se determina fuera de la empresa y explica su producción e ingresos: es una variable exógena (independiente). Las otras dependen de ella.'),
  (9, '¿Cuál de las siguientes es una variable stock?',
   '["Las ventas realizadas durante junio.", "La inversión realizada durante el primer semestre.", "La producción mensual de la mina.", "Las 45.000 toneladas de mineral almacenadas al 30 de junio."]'::jsonb,
   3, 'Una variable stock se mide en un momento determinado (al 30 de junio). Las demás se miden a lo largo de un período: son flujos.'),
  (10, 'Una empresa tuvo ingresos nominales de $150 millones con un índice de precios de 125 (base 100). ¿Cuál es su ingreso real?',
   '["$120 millones.", "$187,5 millones.", "$150 millones.", "$125 millones."]'::jsonb,
   0, 'Ingreso real = ingreso nominal ÷ índice de precios × 100 = 150 ÷ 125 × 100 = 120 millones.')
) as v(orden, enunciado, opciones, correcta, explicacion)
where not exists (select 1 from public.preguntas);

-- ---------------------------------------------------------------------
-- ALTA DE LA DOCENTE (ejecutar DESPUÉS de crear su usuario en
-- Authentication → Users → Add user, con email y contraseña):
--
--   insert into public.admins (user_id, email)
--   select id, email from auth.users where email = 'EMAIL_DE_LA_DOCENTE';
-- ---------------------------------------------------------------------
