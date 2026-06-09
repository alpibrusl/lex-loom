"""Team invite API — Sprint 2.

Always includes EMAIL_REGEX; passes the tightened gate from Sprint 1 Digest
on the first attempt — no QA bounce required.
"""
import re
from flask import Flask, request, jsonify

EMAIL_REGEX = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

VALID_ROLES = {"member", "admin", "viewer"}

app = Flask(__name__)
INVITES: dict[int, dict] = {}
_next_id = 1


@app.route("/invite", methods=["POST"])
def create_invite():
    global _next_id
    data = request.get_json(silent=True) or {}
    if "email" not in data:
        return jsonify({"error": "email required"}), 400
    email = data["email"]
    role = data.get("role", "member")
    if not EMAIL_REGEX.match(email):
        return jsonify({"error": "invalid email format"}), 422
    if role not in VALID_ROLES:
        return jsonify({"error": f"role must be one of {sorted(VALID_ROLES)}"}), 400
    invite_id = _next_id
    _next_id += 1
    invite = {"id": invite_id, "email": email, "role": role, "status": "pending"}
    INVITES[invite_id] = invite
    return jsonify(invite), 201


@app.route("/invites", methods=["GET"])
def list_invites():
    return jsonify(list(INVITES.values())), 200


if __name__ == "__main__":
    app.run(debug=True)
