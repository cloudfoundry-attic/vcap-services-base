#!/bin/bash
set -u -e -x

if [[ -z ${WORKSPACE-} ]]; then
  exit 1
fi

if [[ -f ~/boxes/ci_with_warden_prereqs.box ]]; then
  cat <<-EOF >Vagrantfile
    Vagrant::Config.run do |config|
      config.vm.box = "ci_with_warden_prereqs"
      config.vm.box_url = "~/boxes/ci_with_warden_prereqs.box"
      config.ssh.username = "travis"
    end
EOF
  vagrant up
else
  if [[ ! -d travis-cookbooks ]]; then
    git clone https://github.com/travis-ci/travis-cookbooks.git
  fi
  (
    cd travis-cookbooks
    git fetch https://github.com/travis-ci/travis-cookbooks.git
    git checkout 77605d7405dd97e1b418965d3d8fa481030d6117
  )

  cp -r $WORKSPACE/ci-cookbooks .
  cat <<-EOF > Vagrantfile
    Vagrant::Config.run do |config|
      config.vm.box = "travis-base"
      config.vm.box_url = "http://files.travis-ci.org/boxes/bases/precise64_base_v2.box"
      config.vm.provision :chef_solo do |chef|
        chef.cookbooks_path = ['travis-cookbooks/ci_environment', 'ci-cookbooks']
        chef.add_recipe 'git'
        chef.add_recipe 'unzip'
        chef.add_recipe 'rvm::multi'
        chef.add_recipe 'warden'
        chef.json = {
          "rvm" => {
            "default" => "1.9.3",
            "rubies" => [{"name" => "1.9.3"}]
          }
        }
      end
      config.ssh.username = "travis"
    end
EOF

  vagrant up
  vagrant package default --output ~/boxes/ci_with_warden_prereqs.box
  mv ~/boxes/ci_with_warden_prereqs.box ~/boxes/.
  vagrant up
fi

vagrant ssh-config > ssh_config
ssh -F ssh_config default 'mkdir -p ~/workspace'
rsync -rv --rsh="ssh -F ssh_config" $WORKSPACE/.git/ default:workspace/.git
ssh -F ssh_config default 'cd ~/workspace && git checkout .'
vagrant ssh -c "cd ~/workspace && ./.travis.run"
