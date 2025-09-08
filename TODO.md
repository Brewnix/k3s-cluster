# TODO

## bootstrap and deployment for

- Nvidia Orin AGX nodes
- Nvidie Orin NX nodes
- Standard AMD64 nodes
- Raspberry PI nodes

## Design

- Based on k3s
- etcd store on 3 or more nodes
- Should have network figured out at cluster level (subnet allocation/VLAN)
- Node naming dynamic and based on node type/cluster name
- All nodes should be server by default.  Agent only nodes added manually after initial deployment?
- Have prometheus and a few other standard containers to deploy
- Setup for helm and operator deployments
- postgresql from nas optional
- storage, backups, etc. all provided by nas optionally
