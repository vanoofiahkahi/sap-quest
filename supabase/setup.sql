-- TransQuest: server hosting
-- Paste this whole file into the Supabase SQL Editor and press RUN. It is safe to run again.
--
-- The game runs inside these database functions, so it keeps going when the teacher's
-- device sleeps, reloads or loses its connection. The page talks to the database only
-- through the six functions granted at the bottom of this file. The tables have row level
-- security switched on with no policies, so nobody can read or change them directly: the
-- answers stay on the server until a question is revealed.

create table if not exists public.tq_games (
  code       text primary key,
  token      text not null,
  g          jsonb not null,
  bank       jsonb not null,
  v          bigint not null default 1,
  created_at timestamptz not null default now(),
  touched_at timestamptz not null default now()
);
create table if not exists public.tq_seen (
  code text not null references public.tq_games(code) on delete cascade,
  cid  text not null,
  seen timestamptz not null default now(),
  primary key (code, cid)
);
alter table public.tq_games enable row level security;
alter table public.tq_seen  enable row level security;

-- ---------------------------------------------------------------- small helpers
create or replace function public.tq_now() returns numeric language sql as $$
  select extract(epoch from clock_timestamp())::numeric $$;

-- same rules as clean() in index.html: no control characters, trimmed, capitals, cut to n
create or replace function public.tq_clean(s text, n int) returns text language sql immutable as $$
  select left(upper(btrim(regexp_replace(coalesce(s,''), '[\x01-\x1f]', '', 'g'))), n) $$;

-- same rules as normAns() in index.html: capitals, punctuation, extra spaces and a leading
-- "a", "an", "the" or "it" do not matter
create or replace function public.tq_norm(s text) returns text language sql immutable as $$
  select regexp_replace(btrim(regexp_replace(lower(coalesce(s,'')), '[^a-z0-9]+', ' ', 'g')), '^(the|an|a|it) (?=.)', '') $$;

create or replace function public.tq_color(i int) returns text language sql immutable as $$
  select (array['#3fa9f5','#ffb020','#3ccf4e','#ff6fae','#b98cff','#ff4d5e','#2ee6d6','#ffe14d','#ff8a3d','#8fd16a','#6f8cff','#e8e8e8','#d97a4a','#c6f05a','#f07aff'])[(i % 15) + 1] $$;

create or replace function public.tq_newteam(nm text, players jsonb, i int, secs int) returns jsonb language sql immutable as $$
  select jsonb_build_object('name',nm,'players',players,'color',public.tq_color(i),'score',0,'time',secs,'right',0,'steals',0,'out',false,'last','') $$;

create or replace function public.tq_tset(g jsonb, i int, k text, val jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(g, array['teams', i::text, k], val) $$;

create or replace function public.tq_log(g jsonb, txt text) returns jsonb language sql immutable as $$
  select jsonb_set(g, '{log}', coalesce((
    select jsonb_agg(e order by o)
    from jsonb_array_elements(jsonb_build_array(jsonb_build_object('at', g->'now', 'text', txt)) || coalesce(g->'log', '[]'::jsonb)) with ordinality x(e, o)
    where o <= 40), '[]'::jsonb)) $$;

-- names of the players on a team, in the order they joined
create or replace function public.tq_members(g jsonb, ti int) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(c.value->>'name' order by (c.value->>'n')::int), '[]'::jsonb)
  from jsonb_each(g->'clients') c where (c.value->>'team')::int = ti $$;

create or replace function public.tq_eligible(g jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg((o - 1)::int order by o), '[]'::jsonb)
  from jsonb_array_elements(g->'teams') with ordinality x(t, o)
  where jsonb_typeof(g->'cur') = 'object'
    and not (t->>'out')::boolean
    and not (g->'cur'->'tried') @> to_jsonb((o - 1)::int) $$;

create or replace function public.tq_over(g jsonb) returns boolean language sql immutable as $$
  select ((g->>'used')::int >= 25 and (g->>'round')::int >= (g->>'rounds')::int)
      or not exists (select 1 from jsonb_array_elements(g->'teams') t where not (t->>'out')::boolean) $$;

create or replace function public.tq_advance(g jsonb) returns int language plpgsql immutable as $$
declare v_n int := jsonb_array_length(g->'teams'); v_k int; v_i int;
begin
  for v_k in 1..v_n loop
    v_i := ((g->>'turn')::int + v_k) % v_n;
    if not (g->'teams'->v_i->>'out')::boolean then return v_i; end if;
  end loop;
  return -1;
end $$;

create or replace function public.tq_reset(g jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(jsonb_set(g, '{board}',
    (select jsonb_agg(jsonb_build_object('s','open','by',null,'label','','color','')) from generate_series(1, 25))), '{used}', '0') $$;

-- ---------------------------------------------------------------- game engine
-- These mirror startGame, doPick, doAnswer, offerSteal, doBuzz, finish, nextTurn, onTimeOut
-- and skipTurn in index.html. Each takes the game state and returns the new state.

create or replace function public.tq_end(g jsonb) returns jsonb language sql immutable as $$
  select public.tq_log(jsonb_set(jsonb_set(g, '{phase}', '"end"'), '{paused}', 'false'), 'Game over') $$;

create or replace function public.tq_start(g jsonb) returns jsonb language plpgsql as $$
declare v_n int := jsonb_array_length(g->'teams'); v_i int; v_turn int;
begin
  for v_i in 0..v_n-1 loop
    g := jsonb_set(g, array['teams', v_i::text], (g->'teams'->v_i) ||
      jsonb_build_object('score',0,'time',(g->>'secs')::int,'right',0,'steals',0,'out',false,'last',''));
  end loop;
  v_turn := floor(random() * v_n)::int;
  g := g || jsonb_build_object('turn',v_turn,'ans',v_turn,'round',1,'cur',null,'paused',false,'phase','board');
  g := public.tq_reset(g);
  return public.tq_log(g, 'Game started with ' || v_n || ' teams');
end $$;

create or replace function public.tq_finish(g jsonb, winner int) returns jsonb language plpgsql immutable as $$
declare v_c jsonb := g->'cur'; v_idx text; v_t jsonb;
begin
  if jsonb_typeof(v_c) is distinct from 'object' then return g; end if;
  v_idx := v_c->>'idx';
  g := jsonb_set(g, '{phase}', '"feedback"');
  g := jsonb_set(g, '{cur,winner}', coalesce(to_jsonb(winner), 'null'::jsonb));
  g := jsonb_set(g, '{cur,reveal}', 'true');
  if winner is not null then
    v_t := g->'teams'->winner;
    g := jsonb_set(g, array['board', v_idx], jsonb_build_object('s','won','by',winner,
      'label', left(v_t->>'name', 8) || ' +' || (v_c->>'value'), 'color', v_t->>'color'));
  else
    g := jsonb_set(g, array['board', v_idx, 's'], '"missed"');
    g := public.tq_log(g, 'Nobody got it. Answer: ' || (v_c->>'answer'));
  end if;
  return jsonb_set(g, '{used}', to_jsonb((g->>'used')::int + 1));
end $$;

create or replace function public.tq_offer(g jsonb, timed boolean) returns jsonb language plpgsql immutable as $$
declare v_c jsonb := g->'cur';
begin
  if jsonb_array_length(public.tq_eligible(g)) = 0
     or (not (v_c->>'fill')::boolean and 4 - jsonb_array_length(v_c->'wrong') <= 1) then
    return public.tq_finish(g, null);
  end if;
  g := jsonb_set(g, '{phase}', '"steal"');
  g := jsonb_set(g, '{stealUntil}', to_jsonb((g->>'now')::numeric + 10));
  return jsonb_set(g, '{cur,timedOut}', to_jsonb(timed));
end $$;

create or replace function public.tq_pick(g jsonb, bank jsonb, team int, idx int) returns jsonb language plpgsql as $$
declare v_raw jsonb; v_fill boolean; v_ord int[]; v_opts jsonb; v_ans int; v_acc jsonb;
        v_turn int := (g->>'turn')::int; v_ti int; v_li int; v_val int;
begin
  if g->>'phase' <> 'board' or (g->>'paused')::boolean or team <> v_turn then return g; end if;
  if idx is null or idx < 0 or idx > 24 or g->'board'->idx->>'s' <> 'open' then return g; end if;
  v_ti := idx % 5; v_li := idx / 5; v_val := (v_li + 1) * 100;
  v_raw := bank->((g->>'round')::int - 1)->idx;
  if v_raw is null then return g; end if;
  v_fill := v_raw ? 'f';
  if v_fill then
    v_opts := '[]'::jsonb; v_ans := -1;
    select jsonb_agg(public.tq_norm(x)) into v_acc from jsonb_array_elements_text(v_raw->'f') x;
  else
    select array_agg(k order by random()) into v_ord from generate_series(0, 3) k;
    select jsonb_agg(v_raw->'a'->v_ord[j] order by j) into v_opts from generate_series(1, 4) j;
    v_ans := array_position(v_ord, 0) - 1; v_acc := 'null'::jsonb;
  end if;
  g := jsonb_set(g, '{ans}', to_jsonb(v_turn));
  g := jsonb_set(g, '{cur}', jsonb_build_object('idx',idx,'ti',v_ti,'li',v_li,'q',v_raw->>'q','e',v_raw->>'e',
    'fill',v_fill,'opts',v_opts,'ans',v_ans,
    'answer', case when v_fill then v_raw->'f'->>0 else v_raw->'a'->>0 end,
    'accept',v_acc,'value',v_val,'tried',jsonb_build_array(v_turn),'wrong','[]'::jsonb,
    'stealing',false,'winner',null,'reveal',false,'timedOut',false,'t0',g->'now'));
  g := jsonb_set(g, '{phase}', '"question"');
  return public.tq_log(g, (g->'teams'->team->>'name') || ' picked ' || coalesce(g->'topics'->>v_ti, 'TOPIC ' || (v_ti + 1)) || ' ' || v_val);
end $$;

create or replace function public.tq_answer(g jsonb, team int, v jsonb, timed boolean) returns jsonb language plpgsql immutable as $$
declare v_c jsonb := g->'cur'; v_t jsonb; v_guess text := ''; v_i int; v_fill boolean; v_secs int; v_ok boolean; v_nm text;
begin
  if g->>'phase' <> 'question' or team <> (g->>'ans')::int then return g; end if;
  v_fill := (v_c->>'fill')::boolean;
  if not timed then
    if (g->>'paused')::boolean then return g; end if;
    if v_fill then
      if jsonb_typeof(v) is distinct from 'string' then return g; end if;
      v_guess := public.tq_clean(v #>> '{}', 40);
      if public.tq_norm(v_guess) = '' then return g; end if;
    else
      if jsonb_typeof(v) is distinct from 'number' or (v #>> '{}') !~ '^[0-3]$' then return g; end if;
      v_i := (v #>> '{}')::int;
      if (v_c->'wrong') @> to_jsonb(v_i) then return g; end if;
    end if;
  end if;
  v_t := g->'teams'->team; v_nm := v_t->>'name';
  v_secs := round((g->>'now')::numeric - (v_c->>'t0')::numeric);
  v_ok := not timed and (case when v_fill then (v_c->'accept') ? public.tq_norm(v_guess) else v_i = (v_c->>'ans')::int end);
  if v_ok then
    g := public.tq_tset(g, team, 'score', to_jsonb((v_t->>'score')::int + (v_c->>'value')::int));
    g := public.tq_tset(g, team, 'right', to_jsonb((v_t->>'right')::int + 1));
    if (v_c->>'stealing')::boolean then g := public.tq_tset(g, team, 'steals', to_jsonb((v_t->>'steals')::int + 1)); end if;
    g := public.tq_tset(g, team, 'last', to_jsonb('✓'::text));
    g := public.tq_log(g, v_nm || (case when (v_c->>'stealing')::boolean then ' STOLE it' else ' answered correctly' end)
      || ' (+' || (v_c->>'value') || ', ' || v_secs || 's)');
    return public.tq_finish(g, team);
  end if;
  g := public.tq_tset(g, team, 'last', to_jsonb((case when timed then '⏱' else '✗' end)::text));
  if timed then
    g := public.tq_log(g, v_nm || ' ran out of time');
  else
    g := jsonb_set(g, '{cur,wrong}', (v_c->'wrong') || (case when v_fill then to_jsonb(v_guess) else to_jsonb(v_i) end));
    g := public.tq_log(g, v_nm || ' answered ' || (case when v_fill then '"' || v_guess || '"' else substr('ABCD', v_i + 1, 1) end)
      || ' - wrong (' || v_secs || 's)');
  end if;
  return public.tq_offer(g, timed);
end $$;

create or replace function public.tq_buzz(g jsonb, team int) returns jsonb language plpgsql immutable as $$
begin
  if g->>'phase' <> 'steal' or (g->>'paused')::boolean or not public.tq_eligible(g) @> to_jsonb(team) then return g; end if;
  g := jsonb_set(g, '{cur,tried}', (g->'cur'->'tried') || to_jsonb(team));
  g := jsonb_set(g, '{cur,stealing}', 'true');
  g := jsonb_set(g, '{cur,t0}', g->'now');
  g := g || jsonb_build_object('ans', team, 'phase', 'question');
  return public.tq_log(g, (g->'teams'->team->>'name') || ' is trying to steal');
end $$;

create or replace function public.tq_timeout(g jsonb, i int) returns jsonb language plpgsql immutable as $$
declare v_a int;
begin
  g := public.tq_tset(g, i, 'out', 'true');
  if g->>'phase' = 'question' and i = (g->>'ans')::int then return public.tq_answer(g, i, null, true); end if;
  g := public.tq_log(g, (g->'teams'->i->>'name') || ' ran out of time and is out');
  if public.tq_over(g) then return public.tq_end(g); end if;
  v_a := public.tq_advance(g);
  if v_a < 0 then return public.tq_end(g); end if;
  return g || jsonb_build_object('turn', v_a, 'ans', v_a);
end $$;

create or replace function public.tq_next(g jsonb) returns jsonb language plpgsql immutable as $$
declare v_a int;
begin
  if g->>'phase' <> 'feedback' then return g; end if;
  g := jsonb_set(g, '{cur}', 'null');
  if public.tq_over(g) then return public.tq_end(g); end if;
  v_a := public.tq_advance(g);
  if v_a < 0 then return public.tq_end(g); end if;
  g := g || jsonb_build_object('turn', v_a, 'ans', v_a, 'phase', 'board');
  if (g->>'used')::int >= 25 then
    g := public.tq_reset(jsonb_set(g, '{round}', to_jsonb((g->>'round')::int + 1)));
    g := public.tq_log(g, 'Round ' || (g->>'round') || ' started');
  end if;
  return g;
end $$;

create or replace function public.tq_skip(g jsonb) returns jsonb language plpgsql immutable as $$
declare v_a int; v_from text;
begin
  if g->>'phase' <> 'board' then return g; end if;
  v_from := g->'teams'->((g->>'turn')::int)->>'name';
  v_a := public.tq_advance(g);
  if v_a < 0 then return g; end if;
  return public.tq_log(g || jsonb_build_object('turn', v_a, 'ans', v_a), 'Teacher skipped ' || v_from || '''s turn');
end $$;

-- A team's clock only runs while it is picking or answering. Nothing ticks on the server:
-- the time used is charged whenever somebody calls in, and time-outs are applied then.
create or replace function public.tq_settle(g jsonb) returns jsonb language plpgsql immutable as $$
declare v_now numeric := (g->>'now')::numeric; v_i int; v_rem numeric;
begin
  if (g->>'paused')::boolean then return g; end if;
  if g->>'phase' in ('board', 'question') and jsonb_typeof(g->'clockAt') = 'number' then
    v_i := case when g->>'phase' = 'board' then (g->>'turn')::int else (g->>'ans')::int end;
    if not (g->'teams'->v_i->>'out')::boolean then
      v_rem := greatest(0, (g->'teams'->v_i->>'time')::numeric - (v_now - (g->>'clockAt')::numeric));
      g := public.tq_tset(g, v_i, 'time', to_jsonb(v_rem));
      g := jsonb_set(g, '{clockAt}', to_jsonb(v_now));
      if v_rem = 0 then g := public.tq_timeout(g, v_i); end if;
    end if;
  elsif g->>'phase' = 'steal' and v_now >= (g->>'stealUntil')::numeric then
    g := public.tq_finish(public.tq_log(g, 'Nobody stole in time'), null);
  end if;
  return g;
end $$;

create or replace function public.tq_clock(g jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(g, '{clockAt}', case when g->>'phase' in ('board','question') and not (g->>'paused')::boolean then g->'now' else 'null'::jsonb end) $$;

-- true when a clock has run out or the steal window has closed and nobody has applied it yet
create or replace function public.tq_due(g jsonb) returns boolean language plpgsql as $$
declare v_now numeric := public.tq_now(); v_i int;
begin
  if (g->>'paused')::boolean then return false; end if;
  if g->>'phase' = 'steal' then return v_now >= (g->>'stealUntil')::numeric; end if;
  if g->>'phase' in ('board', 'question') and jsonb_typeof(g->'clockAt') = 'number' then
    v_i := case when g->>'phase' = 'board' then (g->>'turn')::int else (g->>'ans')::int end;
    return not (g->'teams'->v_i->>'out')::boolean
       and (g->'teams'->v_i->>'time')::numeric - (v_now - (g->>'clockAt')::numeric) <= 0;
  end if;
  return false;
end $$;

-- what a device is allowed to see. Students never get the answer before it is revealed.
create or replace function public.tq_view(g jsonb, host boolean) returns jsonb language plpgsql as $$
declare v_now numeric := public.tq_now(); v_run int := -1; v_c jsonb := g->'cur'; v_cur jsonb := 'null'::jsonb;
        v_teams jsonb; v_steal numeric := 0; v_show boolean;
begin
  if not (g->>'paused')::boolean and g->>'phase' in ('board', 'question') and jsonb_typeof(g->'clockAt') = 'number' then
    v_run := case when g->>'phase' = 'board' then (g->>'turn')::int else (g->>'ans')::int end;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('name',t->>'name','players',t->'players','color',t->>'color','score',(t->>'score')::int,
      'time', ceil(greatest(0, (t->>'time')::numeric - case when o - 1 = v_run and not (t->>'out')::boolean then v_now - (g->>'clockAt')::numeric else 0 end)),
      'out',(t->>'out')::boolean,'right',(t->>'right')::int,'steals',(t->>'steals')::int,
      'slots', jsonb_array_length(public.tq_members(g, (o - 1)::int)))
      || case when host then jsonb_build_object('last', t->>'last') else '{}'::jsonb end order by o), '[]'::jsonb)
    into v_teams from jsonb_array_elements(g->'teams') with ordinality x(t, o);
  if g->>'phase' = 'steal' then
    v_steal := ceil(case when (g->>'paused')::boolean then (g->>'stealLeft')::numeric else greatest(0, (g->>'stealUntil')::numeric - v_now) end);
  end if;
  if jsonb_typeof(v_c) = 'object' then
    v_show := host or (v_c->>'reveal')::boolean;
    v_cur := jsonb_build_object('idx',v_c->'idx','ti',v_c->'ti','li',v_c->'li','value',v_c->'value','q',v_c->'q','fill',v_c->'fill',
      'opts',v_c->'opts','wrong',v_c->'wrong','stealing',v_c->'stealing','tried',v_c->'tried',
      'eligible', case when g->>'phase' = 'steal' then public.tq_eligible(g) else '[]'::jsonb end,
      'timedOut',v_c->'timedOut','reveal',v_c->'reveal','winner',v_c->'winner',
      'ans', case when v_show then v_c->'ans' else 'null'::jsonb end,
      'answer', case when v_show then v_c->'answer' else 'null'::jsonb end,
      'e', case when v_show then v_c->'e' else 'null'::jsonb end);
  end if;
  return jsonb_build_object('t','state','phase',g->'phase','mode',g->'mode','size',g->'size','secs',g->'secs','paused',g->'paused',
    'round',g->'round','rounds',g->'rounds','turn',g->'turn','ans',g->'ans','used',g->'used','stealLeft',v_steal,'teams',v_teams,
    'board', coalesce((select jsonb_agg(jsonb_build_object('s',b->'s','label',b->'label','color',b->'color') order by o)
                       from jsonb_array_elements(g->'board') with ordinality y(b, o)), '[]'::jsonb),
    'cur', v_cur);
end $$;

-- applies anything that is overdue (a clock at 0:00, a steal window that has closed)
create or replace function public.tq_tick(p_code text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_g jsonb;
begin
  select g into v_g from tq_games where code = p_code for update;
  if not found or not public.tq_due(v_g) then return; end if;
  v_g := jsonb_set(v_g, '{now}', to_jsonb(public.tq_now()));
  v_g := public.tq_clock(public.tq_settle(v_g));
  update tq_games set g = v_g, v = v + 1, touched_at = now() where code = p_code;
end $$;

-- ---------------------------------------------------------------- functions the page calls

-- teacher: create a room. p = {mode, size, secs, rounds, teams:[names], topics:[names], bank:[[25 questions] per round]}
create or replace function public.tq_create(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text; v_tok text := replace(gen_random_uuid()::text, '-', ''); v_mode text := p->>'mode';
        v_size int; v_secs int; v_rounds int; v_teams jsonb := '[]'::jsonb; v_nm text; v_i int; v_n int; v_q jsonb; v_g jsonb;
begin
  if p is null or octet_length(p::text) > 200000 then raise exception 'tq: request too large'; end if;
  if v_mode is null or v_mode not in ('team', 'student') then raise exception 'tq: bad mode'; end if;
  v_size := least(6, greatest(1, coalesce((p->>'size')::int, 2)));
  v_secs := least(3600, greatest(5, coalesce((p->>'secs')::int, 300)));
  v_rounds := least(2, greatest(1, coalesce((p->>'rounds')::int, 1)));
  if jsonb_typeof(p->'bank') is distinct from 'array' or jsonb_array_length(p->'bank') < v_rounds then raise exception 'tq: bad question bank'; end if;
  for v_i in 0..v_rounds-1 loop
    if jsonb_typeof(p->'bank'->v_i) is distinct from 'array' or jsonb_array_length(p->'bank'->v_i) <> 25 then raise exception 'tq: bad question bank'; end if;
    for v_q in select * from jsonb_array_elements(p->'bank'->v_i) loop
      if jsonb_typeof(v_q->'q') is distinct from 'string'
         or not ((jsonb_typeof(v_q->'a') = 'array' and jsonb_array_length(v_q->'a') = 4)
              or (jsonb_typeof(v_q->'f') = 'array' and jsonb_array_length(v_q->'f') >= 1)) then
        raise exception 'tq: bad question';
      end if;
    end loop;
  end loop;
  if v_mode = 'student' then
    v_n := least(15, greatest(2, case when jsonb_typeof(p->'teams') = 'array' then jsonb_array_length(p->'teams') else 0 end));
    for v_i in 0..v_n-1 loop
      v_nm := public.tq_clean(p->'teams'->>v_i, 14);
      if v_nm = '' then v_nm := 'TEAM ' || (v_i + 1); end if;
      v_teams := v_teams || jsonb_build_array(public.tq_newteam(v_nm, '[]'::jsonb, v_i, v_secs));
    end loop;
  end if;
  delete from tq_games where touched_at < now() - interval '12 hours';
  loop
    v_code := (100000 + floor(random() * 900000))::int::text;
    exit when not exists (select 1 from tq_games where code = v_code);
  end loop;
  v_g := jsonb_build_object('mode',v_mode,'size',v_size,'secs',v_secs,'rounds',v_rounds,'phase','lobby','teams',v_teams,
    'turn',0,'ans',0,'used',0,'round',1,'cur',null,'paused',false,'board','[]'::jsonb,'log','[]'::jsonb,
    'clients','{}'::jsonb,'kicked','{}'::jsonb,'seq',0,'clockAt',null,'stealUntil',0,'stealLeft',0,
    'topics', case when jsonb_typeof(p->'topics') = 'array' then p->'topics' else '[]'::jsonb end, 'now', public.tq_now());
  insert into tq_games(code, token, g, bank) values (v_code, v_tok, v_g, p->'bank');
  return jsonb_build_object('code', v_code, 'token', v_tok);
end $$;

-- student device: is there a server game with this code?
create or replace function public.tq_has(p_code text) returns boolean language sql security definer set search_path = public, pg_temp as $$
  select exists (select 1 from tq_games where code = p_code and g->>'phase' <> 'closed') $$;

-- student device: hello, join, pick, answer, buzz. Returns the replies for that device.
create or replace function public.tq_msg(p_code text, p_cid text, p_msg jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_g jsonb; v_bank jsonb; v_cid text := left(coalesce(p_cid, ''), 40); v_kind text := p_msg->>'t'; v_c jsonb; v_out jsonb := '[]'::jsonb;
        v_team int; v_n int; v_base text; v_name text; v_k int; v_p jsonb; v_ti int; v_nm text; v_seq int;
        v_started constant text := 'This game has already started. Ask your teacher to start a new one.';
begin
  if length(v_cid) < 8 or p_msg is null or octet_length(p_msg::text) > 2000 then return v_out; end if;
  select g, bank into v_g, v_bank from tq_games where code = p_code for update;
  if not found then return jsonb_build_array(jsonb_build_object('t', 'nogame')); end if;
  if v_g->>'phase' = 'closed' then return jsonb_build_array(jsonb_build_object('t', 'kicked', 'msg', v_g->>'closedMsg')); end if;
  v_g := public.tq_settle(jsonb_set(v_g, '{now}', to_jsonb(public.tq_now())));
  v_c := v_g->'clients'->v_cid;

  if v_kind = 'hello' then
    v_g := v_g #- array['kicked', v_cid];
    if v_c is not null and (v_c->>'team')::int < 0 and v_g->>'phase' <> 'lobby' then
      v_out := jsonb_build_array(jsonb_build_object('t', 'reject', 'msg', v_started));
    elsif v_c is not null then
      v_out := jsonb_build_array(jsonb_build_object('t','welcome','mode',v_g->'mode','size',v_g->'size','joined',(v_c->>'team')::int >= 0));
    elsif v_g->>'phase' <> 'lobby' then
      v_out := jsonb_build_array(jsonb_build_object('t', 'reject', 'msg', v_started));
    elsif (select count(*) from jsonb_object_keys(v_g->'clients')) >= 120 then
      v_out := jsonb_build_array(jsonb_build_object('t', 'reject', 'msg', 'This game is full.'));
    else
      v_g := jsonb_set(v_g, array['clients', v_cid], jsonb_build_object('team', -1, 'name', '', 'n', 0));
      v_out := jsonb_build_array(jsonb_build_object('t','welcome','mode',v_g->'mode','size',v_g->'size','joined',false));
    end if;

  elsif v_c is null then
    null;

  elsif v_kind = 'join' then
    if (v_c->>'team')::int >= 0 then
      v_out := jsonb_build_array(jsonb_build_object('t', 'joined'));
    elsif v_g->>'phase' <> 'lobby' then
      v_out := jsonb_build_array(jsonb_build_object('t', 'reject', 'msg', v_started));
    else
      v_n := jsonb_array_length(v_g->'teams'); v_seq := (v_g->>'seq')::int + 1;
      if v_g->>'mode' = 'team' then
        if v_n >= 15 then
          v_out := jsonb_build_array(jsonb_build_object('t', 'joinerr', 'msg', 'This game is full (15 teams).'));
        else
          v_base := public.tq_clean(p_msg->>'team', 14);
          if v_base = '' then v_base := 'TEAM ' || (v_n + 1); end if;
          v_name := v_base; v_k := 2;
          while exists (select 1 from jsonb_array_elements(v_g->'teams') t where t->>'name' = v_name) loop
            v_name := left(v_base, 12) || ' ' || v_k; v_k := v_k + 1;
          end loop;
          select coalesce(jsonb_agg(public.tq_clean(x.e #>> '{}', 12) order by x.o), '[]'::jsonb) into v_p
            from jsonb_array_elements(case when jsonb_typeof(p_msg->'players') = 'array' then p_msg->'players'
                                           else jsonb_build_array(p_msg->'p1', p_msg->'p2') end) with ordinality x(e, o)
            where x.o <= (v_g->>'size')::int;
          v_g := jsonb_set(v_g, '{teams}', (v_g->'teams') || jsonb_build_array(public.tq_newteam(v_name, v_p, v_n, (v_g->>'secs')::int)));
          v_g := jsonb_set(v_g, array['clients', v_cid], jsonb_build_object('team', v_n, 'name', v_name, 'n', v_seq));
          v_g := public.tq_log(jsonb_set(v_g, '{seq}', to_jsonb(v_seq)), v_name || ' joined');
          v_out := jsonb_build_array(jsonb_build_object('t', 'joined'));
        end if;
      else
        v_nm := public.tq_clean(p_msg->>'name', 12);
        if v_nm = '' then
          v_out := jsonb_build_array(jsonb_build_object('t', 'joinerr', 'msg', 'Type your name first.'));
        elsif coalesce(p_msg->>'team', '') ~ '^[0-9]{1,2}$' and (p_msg->>'team')::int < v_n then
          v_ti := (p_msg->>'team')::int;
          if jsonb_array_length(public.tq_members(v_g, v_ti)) >= (v_g->>'size')::int then
            v_out := jsonb_build_array(jsonb_build_object('t', 'joinerr', 'msg', 'That team is full. Pick another team.'));
          else
            v_g := jsonb_set(v_g, array['clients', v_cid], jsonb_build_object('team', v_ti, 'name', v_nm, 'n', v_seq));
            v_g := public.tq_tset(v_g, v_ti, 'players', public.tq_members(v_g, v_ti));
            v_g := public.tq_log(jsonb_set(v_g, '{seq}', to_jsonb(v_seq)), v_nm || ' joined ' || (v_g->'teams'->v_ti->>'name'));
            v_out := jsonb_build_array(jsonb_build_object('t', 'joined'));
          end if;
        end if;
      end if;
    end if;

  elsif (v_c->>'team')::int >= 0 then
    v_team := (v_c->>'team')::int;
    if v_kind = 'pick' and coalesce(p_msg->>'idx', '') ~ '^[0-9]{1,2}$' then
      v_g := public.tq_pick(v_g, v_bank, v_team, (p_msg->>'idx')::int);
    elsif v_kind = 'answer' and jsonb_typeof(v_g->'cur') = 'object' then
      v_g := public.tq_answer(v_g, v_team,
        case when (v_g->'cur'->>'fill')::boolean then to_jsonb(coalesce(p_msg->>'text', '')) else p_msg->'i' end, false);
    elsif v_kind = 'buzz' then
      v_g := public.tq_buzz(v_g, v_team);
    end if;
  end if;

  update tq_games set g = public.tq_clock(v_g), v = v + 1, touched_at = now() where code = p_code;
  return v_out;
end $$;

-- student device: called about once a second. Sends the full state only when it has changed.
create or replace function public.tq_poll(p_code text, p_cid text, p_v bigint) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_g jsonb; v_v bigint; v_cid text := left(coalesce(p_cid, ''), 40); v_view jsonb;
begin
  select g, v into v_g, v_v from tq_games where code = p_code;
  if not found then return jsonb_build_object('t', 'gone'); end if;
  if v_g->>'phase' = 'closed' then return jsonb_build_object('t', 'kicked', 'msg', v_g->>'closedMsg'); end if;
  if (v_g->'kicked') ? v_cid then return jsonb_build_object('t', 'kicked'); end if;
  if public.tq_due(v_g) then
    perform public.tq_tick(p_code);
    select g, v into v_g, v_v from tq_games where code = p_code;
  end if;
  if (v_g->'clients') ? v_cid then
    insert into tq_seen(code, cid, seen) values (p_code, v_cid, now())
      on conflict (code, cid) do update set seen = now() where tq_seen.seen < now() - interval '3 seconds';
  end if;
  v_view := public.tq_view(v_g, false);
  if p_v is not distinct from v_v then
    return jsonb_build_object('t', 'same', 'v', v_v, 'stealLeft', v_view->'stealLeft',
      'times', (select coalesce(jsonb_agg(t->'time' order by o), '[]'::jsonb) from jsonb_array_elements(v_view->'teams') with ordinality x(t, o)));
  end if;
  return v_view || jsonb_build_object('v', v_v, 'you', coalesce((v_g->'clients'->v_cid->>'team')::int, -1));
end $$;

-- teacher view: everything, including the answer, the activity log and who is online
create or replace function public.tq_hostview(p_code text, v_g jsonb, v_v bigint) returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select public.tq_view(v_g, true) || jsonb_build_object('v', v_v, 'code', p_code, 'log', v_g->'log',
    'clients', coalesce((select jsonb_agg(jsonb_build_object('cid', c.key, 'team', (c.value->>'team')::int, 'name', c.value->>'name',
        'online', exists (select 1 from tq_seen s where s.code = p_code and s.cid = c.key and s.seen > now() - interval '8 seconds'))
        order by (c.value->>'n')::int, c.key) from jsonb_each(v_g->'clients') c), '[]'::jsonb)) $$;

create or replace function public.tq_host(p_code text, p_token text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_g jsonb; v_v bigint;
begin
  select g, v into v_g, v_v from tq_games where code = p_code and token = p_token;
  if not found then return jsonb_build_object('t', 'gone'); end if;
  if v_g->>'phase' = 'closed' then return jsonb_build_object('t', 'closed'); end if;
  if public.tq_due(v_g) then
    perform public.tq_tick(p_code);
    select g, v into v_g, v_v from tq_games where code = p_code;
  end if;
  return public.tq_hostview(p_code, v_g, v_v);
end $$;

-- teacher controls: start, next, pause, skip, nosteal, kick, close
create or replace function public.tq_hostact(p_code text, p_token text, p_act text, p_arg jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_g jsonb; v_v bigint; v_cid text; v_c jsonb; v_ti int; v_i int; v_new jsonb; v_map jsonb; v_key text; v_val jsonb;
begin
  select g, v into v_g, v_v from tq_games where code = p_code and token = p_token for update;
  if not found then return jsonb_build_object('t', 'gone'); end if;
  if v_g->>'phase' = 'closed' then return jsonb_build_object('t', 'closed'); end if;
  v_g := public.tq_settle(jsonb_set(v_g, '{now}', to_jsonb(public.tq_now())));

  if p_act = 'start' and v_g->>'phase' = 'lobby' then
    if v_g->>'mode' = 'student' then
      -- drop the teams nobody joined and re-number the rest
      v_new := '[]'::jsonb; v_map := '{}'::jsonb;
      for v_i in 0..jsonb_array_length(v_g->'teams')-1 loop
        if jsonb_array_length(public.tq_members(v_g, v_i)) > 0 then
          v_map := v_map || jsonb_build_object(v_i::text, jsonb_array_length(v_new));
          v_new := v_new || jsonb_build_array(jsonb_set(v_g->'teams'->v_i, '{color}', to_jsonb(public.tq_color(jsonb_array_length(v_new)))));
        end if;
      end loop;
      if jsonb_array_length(v_new) >= 2 then
        for v_key, v_val in select key, value from jsonb_each(v_g->'clients') loop
          v_g := jsonb_set(v_g, array['clients', v_key, 'team'], coalesce(v_map->(v_val->>'team'), '-1'::jsonb));
        end loop;
        v_g := jsonb_set(v_g, '{teams}', v_new);
      end if;
    end if;
    if (select count(*) from jsonb_array_elements(v_g->'teams') with ordinality x(t, o)
        where v_g->>'mode' = 'team' or jsonb_array_length(public.tq_members(v_g, (o - 1)::int)) > 0) >= 2 then
      v_g := public.tq_start(v_g);
    end if;

  elsif p_act = 'next' then
    v_g := public.tq_next(v_g);

  elsif p_act = 'pause' and v_g->>'phase' in ('board', 'question', 'steal', 'feedback') then
    if coalesce((p_arg->>'on')::boolean, false) then
      if not (v_g->>'paused')::boolean then
        v_g := v_g || jsonb_build_object('paused', true, 'stealLeft', greatest(0, (v_g->>'stealUntil')::numeric - (v_g->>'now')::numeric));
        v_g := public.tq_log(v_g, 'Teacher paused the game');
      end if;
    elsif (v_g->>'paused')::boolean then
      v_g := v_g || jsonb_build_object('paused', false, 'stealUntil', (v_g->>'now')::numeric + (v_g->>'stealLeft')::numeric);
      v_g := public.tq_log(v_g, 'Game resumed');
    end if;

  elsif p_act = 'skip' then
    v_g := public.tq_skip(v_g);

  elsif p_act = 'nosteal' and v_g->>'phase' = 'steal' then
    v_g := public.tq_finish(v_g, null);

  elsif p_act = 'kick' and v_g->>'phase' = 'lobby' then
    v_cid := left(coalesce(p_arg->>'cid', ''), 40);
    v_c := v_g->'clients'->v_cid;
    if v_c is not null then
      v_ti := (v_c->>'team')::int;
      v_g := v_g #- array['clients', v_cid];
      v_g := jsonb_set(v_g, array['kicked', v_cid], 'true');
      if v_g->>'mode' = 'team' and v_ti >= 0 then
        v_g := v_g #- array['teams', v_ti::text];
        for v_key, v_val in select key, value from jsonb_each(v_g->'clients') loop
          if (v_val->>'team')::int > v_ti then
            v_g := jsonb_set(v_g, array['clients', v_key, 'team'], to_jsonb((v_val->>'team')::int - 1));
          end if;
        end loop;
        for v_i in 0..jsonb_array_length(v_g->'teams')-1 loop
          v_g := public.tq_tset(v_g, v_i, 'color', to_jsonb(public.tq_color(v_i)));
        end loop;
      elsif v_ti >= 0 then
        v_g := public.tq_tset(v_g, v_ti, 'players', public.tq_members(v_g, v_ti));
      end if;
    end if;

  elsif p_act = 'close' then
    v_g := v_g || jsonb_build_object('phase', 'closed', 'closedMsg', left(coalesce(p_arg->>'msg', 'The teacher closed the game.'), 200));
    update tq_games set g = v_g, v = v + 1, touched_at = now() where code = p_code;
    return jsonb_build_object('t', 'closed');
  end if;

  v_g := public.tq_clock(v_g);
  update tq_games set g = v_g, v = v + 1, touched_at = now() where code = p_code returning v into v_v;
  return public.tq_hostview(p_code, v_g, v_v);
end $$;

-- ---------------------------------------------------------------- who may call what
-- Only the six functions the page uses are open. Everything else is internal.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'tq\_%' loop
    execute format('revoke all on function %s from public', r.f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon, authenticated', r.f);
      if r.proname in ('tq_create', 'tq_has', 'tq_msg', 'tq_poll', 'tq_host', 'tq_hostact') then
        execute format('grant execute on function %s to anon, authenticated', r.f);
      end if;
    end if;
  end loop;
end $$;
