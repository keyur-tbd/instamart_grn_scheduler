"""Local text parser for Instamart (Swiggy) GRN PDFs.

Each item line ends in 15 numbers: Lot MRP, Exp Qty, Recv Qty, Unit Price, Taxable, CGST rate/amt, SGST rate/amt,
IGST rate/amt, CESS rate/amt, Add.Cess, Total. The same SKU can appear on several lines (one per lot, e.g. an old
and a new MRP); LlamaExtract kept only one of them. The footer 'Total: <exp> <recv> <taxable> ... <grand>' lets us
prove a parse is complete: sum(recv) and sum(total) must equal it.

    python instamart_pdf.py some.pdf [...]
"""
import re
import sys
from typing import Any, Dict, List, Optional

NUM = r'-?\d+(?:\.\d+)?'
ITEM = re.compile(rf'^(\d{{1,3}})\s+(\d{{2,9}})\s+(.*?)\s+(\S+)\s+(\S+)\s+' + r'\s+'.join([f'({NUM})'] * 15) + r'$')
TOTAL = re.compile(rf'^Total:\s+((?:{NUM}\s*)+)$')
HDR = {
    'po_number': re.compile(r'PO No\s*:-\s*(\S+)'),
    'po_date': re.compile(r'PO Date\s*:-\s*(\d{1,2}-\d{1,2}-\d{4})'),
    'grn_no': re.compile(r'GRN No\s*:-\s*(\S+)'),
    'grn_date': re.compile(r'GRN Date\s*:-\s*(\d{1,2}-\d{1,2}-\d{4})'),
    'invoice_no': re.compile(r'Invoice No\s*:-\s*(\S+)'),
    'invoice_date': re.compile(r'Invoice Date\s*:-\s*(\d{1,2}-\d{1,2}-\d{4})'),
    'inbound_no': re.compile(r'Inbound No\s*:-\s*(\S+)'),
    'vendor_name': re.compile(r'Vendor Name\s*:-\s*(.+?)\s+PO No'),
}


def _iso(d: Optional[str]) -> Optional[str]:
    if not d:
        return None
    dd, mm, yy = d.split('-')
    return f'{int(yy):04d}-{int(mm):02d}-{int(dd):02d}'


def parse(path: str) -> Dict[str, Any]:
    import pdfplumber
    with pdfplumber.open(path) as pdf:
        text = '\n'.join((p.extract_text() or '') for p in pdf.pages)
    header: Dict[str, Any] = {}
    for k, rx in HDR.items():
        m = rx.search(text)
        v = m.group(1).strip() if m else None
        if v and k == 'invoice_no' and v.startswith('Invoice'):
            v = None
        header[k] = v
    for k in ('po_date', 'grn_date', 'invoice_date'):
        header[k] = _iso(header[k])
    items: List[Dict[str, Any]] = []
    total = None
    for raw in text.splitlines():
        line = raw.strip()
        t = TOTAL.match(line)
        if t:
            g = [float(x) for x in t.group(1).split()]
            total = {'exp': g[0], 'recv': g[1], 'taxable': g[2], 'grand': g[-1], 'n': len(g)}
            continue
        m = ITEM.match(line)
        if not m:
            continue
        g = m.groups()
        n = [float(x) for x in g[5:]]
        items.append({'sr': int(g[0]), 'sku_code': g[1], 'desc_head': g[2], 'vendor_sku': g[3], 'bin_lot': g[4],
                      'lot_mrp': n[0], 'exp_qty': n[1], 'recv_qty': n[2], 'unit_price': n[3], 'taxable_value': n[4],
                      'cgst': n[6], 'sgst': n[8], 'igst': n[10], 'cess': n[12], 'add_cess': n[13], 'total_inr': n[14]})
    return {'header': header, 'items': items, 'total': total}


def check(r: Dict[str, Any]) -> Optional[str]:
    t, items = r['total'], r['items']
    if not t:
        return 'no Total: row'
    if not items:
        return 'no item lines'
    srs = [i['sr'] for i in items]
    if srs != list(range(1, len(items) + 1)):
        return f'Sr. No. gaps: {srs}'
    recv = sum(i['recv_qty'] for i in items)
    grand = sum(i['total_inr'] for i in items)
    if abs(recv - t['recv']) > 0.001:
        return f'recv {recv} vs printed {t["recv"]}'
    if abs(grand - t['grand']) > 1.0:
        return f'total {grand:.2f} vs printed {t["grand"]:.2f}'
    return None


def per_sku(r: Dict[str, Any]) -> List[Dict[str, Any]]:
    """One line per SKU, as the GRN table and the O2C bridge expect. A SKU received in two lots (old + new MRP)
    prints two lines that repeat the expected qty, so: recv/taxable/tax/total are summed, exp_qty is the max,
    lot_no keeps every lot ('a|b'), lot_mrp/unit_price are the
    lot that received most, and 'lots' keeps the lot lines as printed."""
    out: Dict[str, Dict[str, Any]] = {}
    for it in r['items']:
        o = out.get(it['sku_code'])
        if o is None:
            o = out[it['sku_code']] = {'sku_code': it['sku_code'], 'sku_description': it['desc_head'],
                                       'vendor_sku': it['vendor_sku'], 'sku_bin': it['bin_lot'], 'lot_no': it['bin_lot'],
                                       'lot_mrp': it['lot_mrp'], 'exp_qty': it['exp_qty'], 'recv_qty': 0.0,
                                       'unit_price': it['unit_price'], 'taxable_value': 0.0, 'add_cess': 0.0,
                                       'total_inr': 0.0, 'lots': []}
        else:
            o['exp_qty'] = max(o['exp_qty'], it['exp_qty'])
            o['lot_no'] = f"{o['lot_no']}|{it['bin_lot']}"
            if it['recv_qty'] > max(l['recv_qty'] for l in o['lots']):
                o['lot_mrp'], o['unit_price'] = it['lot_mrp'], it['unit_price']
        o['recv_qty'] += it['recv_qty']
        o['taxable_value'] = round(o['taxable_value'] + it['taxable_value'], 2)
        o['add_cess'] = round(o['add_cess'] + it['add_cess'], 2)
        o['total_inr'] = round(o['total_inr'] + it['total_inr'], 2)
        o['lots'].append({k: it[k] for k in ('sr', 'bin_lot', 'lot_mrp', 'exp_qty', 'recv_qty', 'unit_price', 'total_inr')})
    return list(out.values())


if __name__ == '__main__':
    for p in sys.argv[1:]:
        r = parse(p)
        print(p, r['header'], r['total'])
        for it in r['items']:
            print('  ', it['sr'], it['sku_code'], it['bin_lot'], it['lot_mrp'], it['exp_qty'], it['recv_qty'], it['total_inr'])
        print('  ', check(r) or 'reconciles')
