require 'puppet/face/indirector'

Puppet::Face::Indirector.define(:key, '0.0.1') do
  copyright "Puppet Labs", 2011
  license   "Apache 2 license; see COPYING"

  summary "Create, save, and remove certificate keys."

  description <<-EOT
Keys are created for you automatically when certificate
requests are generated with 'puppet certificate generate'.
  EOT

end