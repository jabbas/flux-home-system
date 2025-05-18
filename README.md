# How to use

Change directory to `bootstrap`

Iterate over *.age files and decrypt them

    for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done

Run the playbook

    ansible-playbook site.yaml

# Encrypt/Decrypt with age

    age -R ~/.ssh/key.pub flux-system-secret.yaml >flux-system-secret.yaml.age
    age -d -i ~/.ssh/key flux-system-secret.yaml.age

# Destroy everything

    rm -f controlplane.yaml talosconfig worker.yaml ~/.talos/config ~/.kube/config && echo 401 402 403 |xargs -n1 ssh pve.home qm stop && echo 401 402 403 |xargs -n1 ssh pve.home qm destroy
