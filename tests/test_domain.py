from decimal import Decimal

import pytest

from invoices.domain import InvalidInvoice, parse_invoice, review

VALID = {
    "number": "FAC-2026-0042",
    "supplier": "SBEE",
    "country": "BJ",
    "currency": "XOF",
    "lines": [
        {"description": "Électricité novembre", "quantity": "1", "unit_price": "185000"},
        {"description": "Frais de compteur", "quantity": "2", "unit_price": "2500.50"},
    ],
}


def test_totals_with_benin_vat():
    invoice = parse_invoice(VALID)
    assert invoice.total_excl_tax == Decimal("190001.00")
    assert invoice.vat_amount == Decimal("34200.18")  # 18 %
    assert invoice.total_incl_tax == Decimal("224201.18")


def test_approved_supplier_under_threshold_is_accepted():
    decision = review(parse_invoice(VALID), {"sbee"}, Decimal("5000000"))
    assert decision.status == "ACCEPTED" and decision.reasons == []


def test_unknown_supplier_and_large_amount_require_review():
    big = {**VALID, "supplier": "Inconnu SARL", "lines": [{"quantity": "1", "unit_price": "9000000"}]}
    decision = review(parse_invoice(big), {"SBEE"}, Decimal("5000000"))
    assert decision.status == "REVIEW_REQUIRED"
    assert len(decision.reasons) == 2


@pytest.mark.parametrize(
    ("patch", "message"),
    [
        ({"number": "x"}, "Numéro"),
        ({"country": "US"}, "Pays"),
        ({"currency": "BTC"}, "Devise"),
        ({"lines": []}, "lignes"),
        ({"lines": [{"quantity": "-1", "unit_price": "10"}]}, "positif"),
        ({"lines": [{"quantity": "abc", "unit_price": "10"}]}, "nombre"),
        ({"lines": [{"quantity": "NaN", "unit_price": "10"}]}, "positif"),
    ],
)
def test_invalid_invoices_are_rejected(patch, message):
    with pytest.raises(InvalidInvoice, match=message):
        parse_invoice({**VALID, **patch})
