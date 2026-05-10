output "server_public_ip" {
  description = "Public IP of the k3s control-plane node"
  value       = aws_instance.server.public_ip
}

output "server_private_ip" {
  description = "Private IP of the k3s control-plane node"
  value       = aws_instance.server.private_ip
}

output "agent_public_ip" {
  description = "Public IP of the k3s agent node"
  value       = aws_instance.agent.public_ip
}

output "agent_private_ip" {
  description = "Private IP of the k3s agent node"
  value       = aws_instance.agent.private_ip
}

output "k3s_token" {
  description = "Shared cluster token (sensitive)"
  value       = local.k3s_token
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Shell command to retrieve and patch the kubeconfig for external kubectl access"
  value       = "ssh ubuntu@${aws_instance.server.public_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127\\.0\\.0\\.1/${aws_instance.server.public_ip}/g'"
}

output "kubectl_nodes_command" {
  description = "Quick check that both nodes have joined the cluster"
  value       = "ssh ubuntu@${aws_instance.server.public_ip} 'sudo k3s kubectl get nodes -o wide'"
}
