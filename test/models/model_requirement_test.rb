require 'test_helper'

class ModelRequirementTest < ActiveSupport::TestCase
  test 'parses a folder/name line with an optional link' do
    requirement = ModelRequirement.parse_line('vae/sub/ae.safetensors https://hf.test/ae.safetensors')

    assert_equal 'vae', requirement.directory
    assert_equal 'sub/ae.safetensors', requirement.name
    assert_equal 'https://hf.test/ae.safetensors', requirement.url
    assert_nil ModelRequirement.parse_line('vae/ae.safetensors').url
  end

  test 'round-trips through lines and hashes' do
    requirement = ModelRequirement.new(directory: 'loras', name: 'a\\b.safetensors', url: 'https://x.test/b')

    assert_equal 'loras/a/b.safetensors https://x.test/b', requirement.to_line
    assert_equal requirement, ModelRequirement.from_h(requirement.to_h)
    assert_equal requirement, ModelRequirement.parse_line(requirement.to_line)
  end

  test 'turns Hugging Face page links into direct file links' do
    page = 'https://huggingface.co/Comfy-Org/hunyuan3D_2.0_repackaged/blob/main/split_files/dit.safetensors'
    dataset = 'https://huggingface.co/datasets/org/repo/blob/v1/a.safetensors'

    assert_equal 'https://huggingface.co/Comfy-Org/hunyuan3D_2.0_repackaged/resolve/main/split_files/dit.safetensors',
                 ModelRequirement.new(directory: 'checkpoints', name: 'dit.safetensors', url: page).url
    assert_equal 'https://huggingface.co/datasets/org/repo/resolve/v1/a.safetensors',
                 ModelRequirement.new(directory: 'vae', name: 'a.safetensors', url: dataset).url
    assert_equal 'https://example.test/org/repo/blob/main/a.safetensors',
                 ModelRequirement.new(directory: 'vae', name: 'a.safetensors',
                                      url: 'https://example.test/org/repo/blob/main/a.safetensors').url
  end

  test 'a valid requirement has no problems' do
    assert_empty ModelRequirement.parse_line('checkpoints/sd15.safetensors https://hf.test/sd15.safetensors').problems
    assert_empty ModelRequirement.parse_line('checkpoints/sd15.safetensors').problems
  end

  test 'rejects odd folders, escaping names and non-http links' do
    assert_match(/models folder/, ModelRequirement.parse_line('../x/y.safetensors').problems.join)
    assert_match(/file name/, ModelRequirement.parse_line('vae/../../etc/passwd').problems.join)
    assert_match(/file name/, ModelRequirement.new(directory: 'vae', name: '/etc/passwd').problems.join)
    assert_match(/file name/, ModelRequirement.parse_line('vae').problems.join)
    assert_match(/http/, ModelRequirement.parse_line('vae/ae.safetensors file:///etc/passwd').problems.join)
    assert_match(/single/, ModelRequirement.parse_line('vae/ae.safetensors https://a.test b').problems.join)
  end
end
