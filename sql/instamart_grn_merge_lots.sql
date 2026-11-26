-- instamart_grn: one row per GRN file x SKU, whatever writes the rows.
--
-- Instamart prints a SKU received in two lots (old + new MRP) as two GRN lines that repeat the expected qty. Stored
-- as two rows, two lots with the SAME received qty look like a repeated export to public.o2c_grn_lines (its dup_seq
-- key has no lot), so one lot is dropped and the invoice reads short: 27BLR-07859 (2026-11-26) showed 78 units short
-- on a GRN that received everything and that Instamart paid in full. The PDF-text parser already writes one row per
-- SKU (instamart_pdf.per_sku); this trigger makes the same true for the LlamaExtract fallback, backfills and manual
-- loads.
--
-- A GRN line is identified by lot + received qty + amount (instamart_grn_line_key), not by lot alone: Instamart can
-- print the same lot twice, a 0-received line and the received one (27MUM-12267: lot ..134 = 0, ..134 = 18,
-- ..353 = 18). Checked 2026-11-26 against 190 GRN PDFs that reconcile to their Total row: this rule matched every one.
--
-- On insert of a row whose (grn_no, sku_code, source_file) already has a row:
--   * every incoming line already in that row (raw_data.lots)  -> skipped (a re-sent copy, already counted)
--   * none of them in it                                        -> merged into that row: recv / taxable / cess /
--     total summed, exp_qty the max (lot lines repeat it), lot_no 'a|b', lot_mrp + unit_price from the lot that
--     received most, raw_data.lots keeps every lot line
--   * partial overlap, or lot_no / grn_no / sku_code missing    -> inserted unchanged (old behaviour)
-- Revised GRNs arrive under a new source_file (<name>__rev<stamp>.pdf), so they never merge into the version they
-- replace.
create or replace function public.instamart_grn_line_key(l jsonb) returns text
language sql immutable
set search_path = pg_catalog
as $$
    select coalesce(l ->> 'bin_lot', '') || '|' ||
           coalesce(round(nullif(l ->> 'recv_qty', '')::numeric, 3)::text, '') || '|' ||
           coalesce(round(nullif(l ->> 'total_inr', '')::numeric, 2)::text, '')
$$;
comment on function public.instamart_grn_line_key(jsonb) is
'Identity of one Instamart GRN lot line (lot | received qty | amount) for instamart_grn_merge_lots().';

create or replace function public.instamart_grn_merge_lots() returns trigger
language plpgsql
set search_path = pg_catalog, public
as $fn$
declare
    ex        record;
    ex_keys   text[];
    new_keys  text[];
    ex_list   jsonb;
    new_list  jsonb;
    ex_best   numeric;
    tbl       text := format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME);
begin
    if new.lot_no is null or btrim(new.lot_no) = '' or new.grn_no is null or new.sku_code is null then
        return new;
    end if;
    -- serialise writers of the same GRN x SKU so two sessions cannot both miss each other's lot
    perform pg_advisory_xact_lock(hashtext('instamart_grn_merge_lots'), hashtext(new.grn_no || '|' || new.sku_code));

    for ex in execute format(
        'select id, lot_no, recv_qty, exp_qty, lot_mrp, unit_price, taxable_value, add_cess, total_inr, raw_data
           from %s where grn_no = $1 and sku_code = $2 and source_file = $3 and lot_no is not null
          order by id', tbl)
        using new.grn_no, new.sku_code, new.source_file
    loop
        ex_list := case jsonb_typeof(ex.raw_data -> 'lots')
                       when 'array'  then ex.raw_data -> 'lots'
                       when 'string' then (ex.raw_data ->> 'lots')::jsonb
                   end;
        if ex_list is null or jsonb_typeof(ex_list) <> 'array' then
            ex_list := jsonb_build_array(jsonb_build_object(
                'bin_lot', ex.lot_no, 'lot_mrp', ex.lot_mrp, 'exp_qty', ex.exp_qty, 'recv_qty', ex.recv_qty,
                'unit_price', ex.unit_price, 'total_inr', ex.total_inr));
        end if;
        new_list := case jsonb_typeof(new.raw_data -> 'lots')
                        when 'array'  then new.raw_data -> 'lots'
                        when 'string' then (new.raw_data ->> 'lots')::jsonb
                    end;
        if new_list is null or jsonb_typeof(new_list) <> 'array' then
            new_list := jsonb_build_array(jsonb_build_object(
                'bin_lot', new.lot_no, 'lot_mrp', new.lot_mrp, 'exp_qty', new.exp_qty, 'recv_qty', new.recv_qty,
                'unit_price', new.unit_price, 'total_inr', new.total_inr));
        end if;
        -- a GRN line is identified by lot + received qty + amount: Instamart can print the SAME lot twice (a
        -- 0-received line and the received one), so the lot number alone does not tell a re-sent copy apart
        ex_keys  := array(select public.instamart_grn_line_key(l) from jsonb_array_elements(ex_list) l);
        new_keys := array(select public.instamart_grn_line_key(l) from jsonb_array_elements(new_list) l);
        if not exists (select 1 from unnest(new_keys) k group by k
                        having count(*) > (select count(*) from unnest(ex_keys) e where e = k)) then
            return null;                                   -- every incoming line is already counted in this row
        elsif new_keys && ex_keys then
            continue;                                      -- partial overlap: leave it to the old behaviour
        end if;
        select max(nullif(l ->> 'recv_qty', '')::numeric) into ex_best from jsonb_array_elements(ex_list) l;

        execute format(
            'update %s set
                lot_no        = $2,
                recv_qty      = $3,
                exp_qty       = $4,
                taxable_value = $5,
                add_cess      = $6,
                total_inr     = $7,
                lot_mrp       = $8,
                unit_price    = $9,
                raw_data      = coalesce(raw_data, ''{}''::jsonb) || $10
              where id = $1', tbl)
        using ex.id,
              ex.lot_no || '|' || new.lot_no,
              coalesce(ex.recv_qty, 0) + coalesce(new.recv_qty, 0),
              greatest(ex.exp_qty, new.exp_qty),
              case when ex.taxable_value is null and new.taxable_value is null then null
                   else coalesce(ex.taxable_value, 0) + coalesce(new.taxable_value, 0) end,
              case when ex.add_cess is null and new.add_cess is null then null
                   else coalesce(ex.add_cess, 0) + coalesce(new.add_cess, 0) end,
              case when ex.total_inr is null and new.total_inr is null then null
                   else coalesce(ex.total_inr, 0) + coalesce(new.total_inr, 0) end,
              case when coalesce(new.recv_qty, 0) > coalesce(ex_best, ex.recv_qty, 0) then new.lot_mrp else ex.lot_mrp end,
              case when coalesce(new.recv_qty, 0) > coalesce(ex_best, ex.recv_qty, 0) then new.unit_price else ex.unit_price end,
              jsonb_build_object('lots', ex_list || new_list,
                                 'lots_merged_by', 'instamart_grn_merge_lots trigger',
                                 'lots_merged_at', now());
        return null;
    end loop;
    return new;
end
$fn$;

comment on function public.instamart_grn_merge_lots() is
'BEFORE INSERT trigger on instamart_grn: keeps one row per GRN file x SKU. A SKU received in two lots is merged into '
'one row (recv summed, exp_qty max, lot_no ''a|b'', raw_data.lots = the lot lines); a re-sent lot already in the row '
'is skipped. Why: o2c_grn_lines dedupes on qty without the lot, so two equal-qty lots counted once (27BLR-07859 '
'read 78 short on a full GRN, 2026-11-26).';

drop trigger if exists instamart_grn_merge_lots on public.instamart_grn;
create trigger instamart_grn_merge_lots
    before insert on public.instamart_grn
    for each row execute function public.instamart_grn_merge_lots();
