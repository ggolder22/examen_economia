-- =====================================================================
--  ACTUALIZACIÓN 2 · Alumnos precargados (ingreso solo con DNI)
--  Ejecutar DESPUÉS de schema.sql en: Supabase → SQL Editor → New query → Run
-- =====================================================================

alter table public.alumnos add column if not exists nro int;

-- El alumno ya no se da de alta: solo ingresa con su DNI si está en la lista
drop function if exists public.alumno_ingresar(text, text, text, text);

create or replace function public.alumno_ingresar(p_dni text, p_dispositivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_dni text := regexp_replace(coalesce(p_dni, ''), '\D', '', 'g');
  a alumnos;
begin
  select * into a from alumnos where dni = v_dni;
  if not found then
    raise exception 'No encontramos ese DNI en la lista del curso. Revisalo o avisale a la docente.';
  end if;
  update alumnos set ultimo_acceso = now() where dni = v_dni;
  perform _log(v_dni, 'ingreso', jsonb_build_object('dispositivo', p_dispositivo));
  return jsonb_build_object('token', a.token, 'dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre);
end $$;

-- Carga o actualiza alumnos: [{ "nro": 1, "dni": "...", "apellido": "...", "nombre": "..." }, ...]
create or replace function public.admin_importar_alumnos(p_lista jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_dni text; v_nuevos int := 0; v_act int := 0;
begin
  perform _exigir_admin();
  if jsonb_typeof(p_lista) <> 'array' then raise exception 'Formato inválido.'; end if;

  for r in select * from jsonb_array_elements(p_lista) loop
    v_dni := regexp_replace(coalesce(r ->> 'dni', ''), '\D', '', 'g');
    if length(v_dni) < 6 or coalesce(trim(r ->> 'apellido'), '') = '' then
      raise exception 'Fila inválida: %', r::text;
    end if;
    if exists (select 1 from alumnos where dni = v_dni) then
      update alumnos set apellido = trim(r ->> 'apellido'), nombre = coalesce(trim(r ->> 'nombre'), ''),
                         nro = coalesce((r ->> 'nro')::int, nro)
       where dni = v_dni;
      v_act := v_act + 1;
    else
      insert into alumnos (dni, apellido, nombre, nro)
      values (v_dni, trim(r ->> 'apellido'), coalesce(trim(r ->> 'nombre'), ''), (r ->> 'nro')::int);
      v_nuevos := v_nuevos + 1;
    end if;
  end loop;

  perform _log(null, 'docente_importa_alumnos', jsonb_build_object('nuevos', v_nuevos, 'actualizados', v_act));
  return jsonb_build_object('nuevos', v_nuevos, 'actualizados', v_act);
end $$;

-- Igual que antes, pero incluye el número de orden y ordena por él
create or replace function public.admin_estado()
returns jsonb language plpgsql security definer set search_path = public as $$
declare c config; v_alumnos jsonb; v_preg jsonb;
begin
  perform _exigir_admin();
  perform _cerrar_vencidos();
  select * into c from config where id = 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'nro', a.nro, 'dni', a.dni, 'apellido', a.apellido, 'nombre', a.nombre,
           'creado', a.creado, 'ultimo_acceso', a.ultimo_acceso,
           'tiene_intento', i.dni is not null, 'iniciado', i.iniciado,
           'respondidas', (select count(*) from jsonb_object_keys(coalesce(i.respuestas, '{}'::jsonb))),
           'entregado', i.entregado, 'entrega_auto', i.entrega_auto,
           'aciertos', i.aciertos, 'total', i.total, 'nota', i.nota)
         order by a.nro nulls last, a.apellido, a.nombre), '[]'::jsonb)
    into v_alumnos
    from alumnos a left join intentos i on i.dni = a.dni;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.orden, p.id), '[]'::jsonb)
    into v_preg from preguntas p;

  return jsonb_build_object('ahora', now(), 'estado', _estado(), 'config', to_jsonb(c),
                            'alumnos', v_alumnos, 'preguntas', v_preg);
end $$;

revoke execute on function public.alumno_ingresar(text, text) from public;
grant  execute on function public.alumno_ingresar(text, text) to anon, authenticated;
revoke execute on function public.admin_importar_alumnos(jsonb) from public, anon;
grant  execute on function public.admin_importar_alumnos(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- LISTA DEL CURSO (32 alumnos)
-- ---------------------------------------------------------------------
insert into public.alumnos (nro, dni, apellido, nombre) values
  ( 1, '44665707', 'Aballay',           'Luciano'),
  ( 2, '44808618', 'Ahumada',           'Celena'),
  ( 3, '41122715', 'Alaniz',            'Rocío'),
  ( 4, '46259518', 'Amaya',             'Mariano Gregorio'),
  ( 5, '42356746', 'Cardozo',           'Sofía Cardozo'),
  ( 6, '44674997', 'Carrizo',           'Matías'),
  ( 7, '47286279', 'Castillo Correa',   'Nehemias Emanuel'),
  ( 8, '47286890', 'Cortez',            'Trinidad Rocío'),
  ( 9, '44527396', 'Cuello Duran',      'Brian Ricardo'),
  (10, '41809100', 'Décimo',            'Gabriela Sofia'),
  (11, '45885328', 'Díaz',              'Milagros'),
  (12, '47624865', 'Escudero Carrizo',  'Isabel Eliana'),
  (13, '43764798', 'Faria-matus',       'Rodrigo'),
  (14, '46544548', 'Flores',            'Alejo'),
  (15, '37833864', 'Galtian Acuña',     'Zuleika Aldana'),
  (16, '41468058', 'Godoy Molina',      'Marilin Tamara'),
  (17, '39651713', 'Gómez',             'Soraya soledad'),
  (18, '34696729', 'Guzman',            'Jonathan David'),
  (19, '47046977', 'López',             'Marcos Ariel'),
  (20, '31658874', 'Navarro',           'Natalia Elizabeth'),
  (21, '44674995', 'Nievas',            'Edgar Leonel'),
  (22, '33236882', 'Núñez',             'Marianela Estefanía'),
  (23, '47360997', 'Ochoa',             'Eliana María lujan'),
  (24, '42207419', 'Olivares Lafuente', 'Mariana Ayelen'),
  (25, '43952459', 'Oviedo',            'Mauricio esequiel'),
  (26, '47478335', 'Pais',              'tobias'),
  (27, '46932470', 'Pereyra Castro',    'Priscila Abril'),
  (28, '32624396', 'Quiroga',           'Belén'),
  (29, '47197399', 'Reinoso',           'Martin'),
  (30, '47239296', 'Sad',               'Yara'),
  (31, '38078637', 'Sánchez',           'Janet Nair'),
  (32, '40995700', 'Vargas Gómez',      'Julieta Pamela')
on conflict (dni) do update
  set nro = excluded.nro, apellido = excluded.apellido, nombre = excluded.nombre;
