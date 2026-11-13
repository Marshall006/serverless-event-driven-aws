"""Règles métier, sans aucune dépendance à AWS (donc testables partout).

Architecture « hexagonale » simplifiée : le cœur métier ne sait rien de S3,
SQS ou DynamoDB. Les handlers Lambda ne font que l'adapter à AWS.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

CENT = Decimal("0.01")
VAT_RATES = {"BJ": Decimal("18"), "CI": Decimal("18"), "SN": Decimal("18"), "TG": Decimal("18"), "FR": Decimal("20")}
INVOICE_NUMBER = re.compile(r"^[A-Z0-9][A-Z0-9/_-]{2,39}$")


class InvalidInvoice(ValueError):
    """La facture est illisible ou incohérente : elle est rejetée."""


@dataclass(frozen=True)
class Line:
    description: str
    quantity: Decimal
    unit_price: Decimal

    @property
    def total(self) -> Decimal:
        return (self.quantity * self.unit_price).quantize(CENT, ROUND_HALF_UP)


@dataclass(frozen=True)
class Invoice:
    number: str
    supplier: str
    country: str
    currency: str
    lines: tuple[Line, ...]

    @property
    def vat_rate(self) -> Decimal:
        return VAT_RATES[self.country]

    @property
    def total_excl_tax(self) -> Decimal:
        return sum((line.total for line in self.lines), Decimal("0"))

    @property
    def vat_amount(self) -> Decimal:
        return (self.total_excl_tax * self.vat_rate / 100).quantize(CENT, ROUND_HALF_UP)

    @property
    def total_incl_tax(self) -> Decimal:
        return self.total_excl_tax + self.vat_amount


@dataclass(frozen=True)
class Decision:
    status: str  # ACCEPTED | REVIEW_REQUIRED
    reasons: list[str] = field(default_factory=list)


def _decimal(value: object, name: str) -> Decimal:
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise InvalidInvoice(f"{name} n'est pas un nombre : {value!r}") from exc
    if not number.is_finite() or number <= 0:
        raise InvalidInvoice(f"{name} doit être strictement positif")
    return number


def parse_invoice(data: dict) -> Invoice:
    """Valide une facture reçue en JSON et la convertit en objet métier."""
    if not isinstance(data, dict):
        raise InvalidInvoice("Le document doit être un objet JSON")
    number = str(data.get("number", "")).strip().upper()
    if not INVOICE_NUMBER.match(number):
        raise InvalidInvoice("Numéro de facture invalide")
    supplier = str(data.get("supplier", "")).strip()
    if not 2 <= len(supplier) <= 120:
        raise InvalidInvoice("Fournisseur manquant ou trop long")
    country = str(data.get("country", "")).upper()
    if country not in VAT_RATES:
        raise InvalidInvoice(f"Pays non pris en charge : {country or '?'}")
    currency = str(data.get("currency", "XOF")).upper()
    if currency not in {"XOF", "EUR", "USD"}:
        raise InvalidInvoice(f"Devise non prise en charge : {currency}")
    raw_lines = data.get("lines")
    if not isinstance(raw_lines, list) or not 1 <= len(raw_lines) <= 500:
        raise InvalidInvoice("La facture doit contenir entre 1 et 500 lignes")
    lines = tuple(
        Line(
            description=str(line.get("description", ""))[:200] or "—",
            quantity=_decimal(line.get("quantity"), f"lines[{i}].quantity"),
            unit_price=_decimal(line.get("unit_price"), f"lines[{i}].unit_price"),
        )
        for i, line in enumerate(raw_lines)
    )
    return Invoice(number, supplier, country, currency, lines)


def review(invoice: Invoice, approved_suppliers: set[str], review_threshold: Decimal) -> Decision:
    """Contrôles de conformité : certaines factures exigent une validation humaine."""
    reasons = []
    if invoice.supplier.casefold() not in {s.casefold() for s in approved_suppliers}:
        reasons.append("Fournisseur non référencé")
    if invoice.total_incl_tax >= review_threshold:
        reasons.append(f"Montant TTC ≥ {review_threshold} {invoice.currency}")
    return Decision("REVIEW_REQUIRED" if reasons else "ACCEPTED", reasons)
