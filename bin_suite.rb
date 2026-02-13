# ---------------------------------------------------------
# TEST 6: Filtrado Complejo (Query String Nested)
# ---------------------------------------------------------
puts "\n[6] Probando Resource.where con filtros anidados..."

begin
  # Esto fallaba antes (generaba string feo en la URL)
  # Al usar Rack, esto genera: ?q[active]=true&q[roles][]=admin
  TestUser.where(q: { active: true, roles: ['admin'] })
  puts "  ✅ PASS: .where generó la query anidada correctamente sin errores."
rescue => e
  puts "  ❌ FAIL: Excepción al generar query: #{e.message}"
end
